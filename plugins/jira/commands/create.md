---
command: create
description: Create a technical task in the sprint project, linked to a source ticket and a release
---

## Bootstrap (required first step)

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/bootstrap.sh"
trap 'rm -f "$JIRA_CURL_CONFIG"' EXIT
```

If the bootstrap fails, surface its error verbatim and stop.

## Argument

`$ARGUMENTS`

## Flow

### 1. Resolve the target project and task-creation defaults

From the overlay:

- `sprint_project_key` = the `projects[]` entry whose `role` matches
  `task_creation.default_project_role` (default: `sprint`).
- `issuetype` = `task_creation.default_issuetype` (default: `Task`).
- `summary_format` = `task_creation.summary_format` — a template string
  with `{space}` and `{title}` placeholders.
- `common_spaces` = `task_creation.common_spaces`.

**Abort if `summary_format` is missing, empty, or does not contain `{title}`**:

```bash
summary_format=$("$JIRA_PYTHON" -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
print(d.get("task_creation", {}).get("summary_format", ""))
' < "$JIRA_OVERLAY_FILE")

if [[ -z "$summary_format" || "$summary_format" != *"{title}"* ]]; then
  printf "ERROR: task_creation.summary_format in %s is missing, empty, or has no {title} placeholder.\nSee %s/config.example.yaml.\n" \
    "$JIRA_OVERLAY_FILE" "$CLAUDE_PLUGIN_ROOT" >&2
  exit 2
fi
```

### 2. Collect information

If the argument doesn't include all of the fields below, prompt for them:

- **Space:** one of `common_spaces` (or a custom one).
- **Title:** a short descriptive sentence.
- **Epic parent:** pick one from the overlay's `epics[]` list or type a
  key.
- **Story points:** estimate (integer). Stored under the custom field
  `custom_fields.story_points`.
- **Assignee:** name or account ID. Resolve via the overlay's `accounts[]`
  list; if unknown, ask the user to add the account or provide an ID.
- **Source ticket (optional):** a key in the source project.
- **Release:** a key in the roadmap project. Ask for it even when the
  argument said nothing about a release, and accept `none` as an answer —
  carry that answer to the confirmation in step 7. Never decide it by
  omission.

### 3. Build the summary

Apply `summary_format` with the collected `space` and `title`. The abort
in step 1 guarantees the template is well-formed.

### 4. Create the issue

Never build JSON by string interpolation — user-supplied `title`, `space`,
`assignee`, etc. can legitimately contain double quotes, backslashes, or
newlines and would break a hand-rolled payload (or worse, inject fields).
Always build the payload with `jq -n --arg ...`:

```bash
body=$(jq -n \
  --arg project    "$sprint_project_key" \
  --arg summary    "$formatted_summary" \
  --arg issuetype  "$issuetype" \
  --arg parent     "$epic_parent" \
  --arg assignee   "$assignee_account_id" \
  --arg sp_field   "$sp_field_id" \
  --argjson sp     "${story_points:-null}" \
  '{
    fields: ({
      project:   { key: $project },
      summary:   $summary,
      issuetype: { name: $issuetype },
      parent:    { key: $parent },
      assignee:  { accountId: $assignee }
    } + (if $sp == null then {} else {($sp_field): $sp} end))
  }')

curl --config "$JIRA_CURL_CONFIG" -X POST \
  -H "Content-Type: application/json" \
  "$JIRA_BASE_URL/rest/api/3/issue" \
  --data "$body"
```

`$sp_field_id` comes from `custom_fields.story_points` in the overlay (e.g.
`customfield_10016`). `--argjson` keeps `$sp` as a number rather than a
string; the `${story_points:-null}` fallback means unestimated tasks
(empty `$story_points`) omit the SP field instead of crashing `jq` with a
parse error.

### 5. Link the new task

Both link types are optional to the API — fire each POST only if the
corresponding key exists. Optional is not the same as skippable in silence:
step 2 asks for the release out loud, and a task created without one is
reported as "no release" in step 7. A task nobody can trace to a release is a
task the roadmap does not know about, and it is the first thing asked in
refinement. Build each payload with `jq -n --arg` so
values with quotes or control characters cannot break the JSON:

```bash
# Source-ticket link (skip entirely if no source key was provided).
if [[ -n "$source_ticket_key" ]]; then
  link=$(jq -n \
    --arg type    "$source_ticket_link_type" \
    --arg source  "$source_ticket_key" \
    --arg target  "$new_task_key" \
    '{
      type: { name: $type },
      inwardIssue:  { key: $source },
      outwardIssue: { key: $target }
    }')

  curl --config "$JIRA_CURL_CONFIG" -X POST \
    -H "Content-Type: application/json" \
    "$JIRA_BASE_URL/rest/api/3/issueLink" \
    --data "$link"
fi

# Release link (same pattern): skip when $release_key is empty.
if [[ -n "$release_key" ]]; then
  link=$(jq -n \
    --arg type    "$release_link_type" \
    --arg source  "$release_key" \
    --arg target  "$new_task_key" \
    '{
      type: { name: $type },
      inwardIssue:  { key: $source },
      outwardIssue: { key: $target }
    }')

  curl --config "$JIRA_CURL_CONFIG" -X POST \
    -H "Content-Type: application/json" \
    "$JIRA_BASE_URL/rest/api/3/issueLink" \
    --data "$link"
fi
```

### 6. Put the issue in the active sprint

Creating an issue never puts it in a sprint — the Sprint field appears on the
create screen but is read-only there, so `customfield_*` in the create payload
is silently ignored. The issue has to be added afterwards through the Agile
API, or it sits in the backlog where the team does not see it.

Run this whenever the target project's role is listed in the overlay's
`sprints.add_to_active_sprint_roles`:

```bash
read_overlay() { "$JIRA_PYTHON" -c "$1" < "$JIRA_OVERLAY_FILE"; }

# Step 1 already resolved the target project. Name the two values this step
# needs: the project key it created in, and the role that selected it.
project_key="$sprint_project_key"
target_role=$(read_overlay '
import sys, yaml
d = yaml.safe_load(sys.stdin)
print(d.get("task_creation", {}).get("default_project_role", "sprint"))
')

wants_sprint=$(read_overlay '
import sys, yaml
d = yaml.safe_load(sys.stdin)
roles = d.get("sprints", {}).get("add_to_active_sprint_roles", []) or []
print("yes" if "'"$target_role"'" in roles else "no")
')

if [[ "$wants_sprint" == "yes" ]]; then
  board_id=$(read_overlay '
import sys, yaml
d = yaml.safe_load(sys.stdin)
print((d.get("sprints", {}).get("boards") or {}).get("'"$project_key"'", ""))
')

  # No board pinned in the overlay: discover it.
  if [[ -z "$board_id" ]]; then
    boards=$(curl -s --config "$JIRA_CURL_CONFIG" \
      "$JIRA_BASE_URL/rest/agile/1.0/board?projectKeyOrId=$project_key&maxResults=50")
    # If more than one scrum board comes back, ASK which one — projects often
    # keep a stale "(OLD)" board next to the live one, and guessing puts the
    # ticket in a sprint nobody looks at. Then offer to pin it in the overlay.
    board_id=$(printf '%s' "$boards" | jq -r '[.values[] | select(.type=="scrum")] | if length == 1 then .[0].id else "" end')
  fi

  sprint_id=$(curl -s --config "$JIRA_CURL_CONFIG" \
    "$JIRA_BASE_URL/rest/agile/1.0/board/$board_id/sprint?state=active" \
    | jq -r '.values[0].id // empty')

  if [[ -n "$sprint_id" ]]; then
    payload=$(jq -n --arg key "$new_task_key" '{issues: [$key]}')
    curl --config "$JIRA_CURL_CONFIG" -X POST \
      -H "Content-Type: application/json" \
      "$JIRA_BASE_URL/rest/agile/1.0/sprint/$sprint_id/issue" \
      --data "$payload"     # 204 No Content on success
  fi
fi
```

If the board has no active sprint, say so and leave the issue in the backlog —
never create a sprint to put it in. Same for an issue that is already resolved:
adding it only pollutes the burndown with work that wasn't done there.

Re-read the issue afterwards and show the sprint name in the confirmation: a
204 means the request was accepted, not that the ticket is where you think.

### 7. Confirm

Show the created key, summary, the sprint it landed in, all applied links, and the ticket URL
(`$JIRA_BASE_URL/browse/<key>`). Name the release the task was tied to, or say
plainly that none was — staying quiet there reads as "linked" to whoever asks
later.
