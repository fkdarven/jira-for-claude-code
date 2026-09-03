---
command: routine
description: Triage routine for incoming support tickets
---

## Bootstrap (required first step)

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/bootstrap.sh"
trap 'rm -f "$JIRA_CURL_CONFIG"' EXIT
```

If the bootstrap fails, surface its error verbatim and stop.

## Flow

### 1. Resolve the source project and relevant transition IDs

Read the overlay (command substitution, never `eval`):

- `support_project_key` = the `projects[]` entry whose `role` matches
  `triage.source_project_role` (default: `support`).
- `target_transition_id` = `transitions.<support_project_key>.<triage.target_transition>`.
- `start_progress_id` = `transitions.<support_project_key>.start_progress`
  (may be missing on workflows that do not need an intermediate step;
  optional).

If `support_project_key` or `target_transition_id` is missing, abort and
tell the user to add them to the overlay.

### 2. List open tickets assigned to the user

```
JQL: project = <support_project_key>
     AND assignee = currentUser()
     AND statusCategory != Done
     ORDER BY status ASC, priority DESC, created DESC
```

Build the request body with `jq -n --arg` (never interpolate into JSON):

```bash
body=$(jq -n --arg jql "project = $support_project_key AND assignee = currentUser() AND statusCategory != Done ORDER BY status ASC, priority DESC, created DESC" \
  '{jql: $jql, fields: ["summary","status","priority","issuetype"], maxResults: 50}')

curl --config "$JIRA_CURL_CONFIG" -X POST \
  -H "Content-Type: application/json" \
  "$JIRA_BASE_URL/rest/api/3/search/jql" \
  --data "$body"
```

### 3. Classify each ticket

Use the categories from `triage.categories` in the overlay (default set:
`bug`, `product_task`, `server_infra`, `docs`, `code_review`). Tag each
ticket with its best-fit category in the output table.

### 4. For each ticket, follow the flow

#### a) Investigate

The overlay optionally documents how the user investigates on
infrastructure (`triage.ssh_config_file`, `triage.host_pattern`,
`triage.ssh_requires_vpn`). If `ssh_config_file` is empty, skip SSH and
investigate via Jira content alone.

If `ssh_config_file` is set, **explicitly ask the user which site the
ticket pertains to** before proceeding — do not guess from the ticket
summary. Format the prompt as:

```
<KEY> — which site slug should I connect to?
(e.g. "site-slug" → host becomes site-slug-web per host_pattern)
[site slug | 'skip']:
```

Derive the host via `host_pattern` with the user-supplied slug. If the
user types `skip`, do not attempt SSH for this ticket.

#### b) Apply the fix

Open-ended — the plugin doesn't ship opinions about which infrastructure
commands are safe. If the user asks for guidance, ask them to share their
runbook rather than guessing.

#### c) Comment on the ticket via API

Write the comment to a file and convert it with the plugin's converter; do not
hand-roll ADF and do not write a throwaway script for it:

```bash
body_json=$("$JIRA_PYTHON" "${CLAUDE_PLUGIN_ROOT}/lib/jira-adf.py" \
  --base-url "$JIRA_BASE_URL" --projects "$project_keys" --wrap comment "$BODY_FILE")

curl --config "$JIRA_CURL_CONFIG" -X POST \
  -H "Content-Type: application/json" \
  "$JIRA_BASE_URL/rest/api/3/issue/$KEY/comment" \
  --data "$body_json"
```

Include: what was done, root cause, commands executed (with secrets redacted),
and any pending items. The part meant for the customer goes inside a
`[[SUCCESS]] … [[/PANEL]]` block (green panel) that opens with a bold
"Resposta ao cliente" paragraph, in customer language. `/jira:comment` wraps this
step with the duplicate check and the issue-link step; prefer it when closing a
single ticket. See `jira-context/SKILL.md` for the converter's input subset.

Every key the comment mentions ships twice: as a link to
`$JIRA_BASE_URL/browse/<KEY>` in the text, and as a real issue link on the
ticket. Bold text is not a reference — whoever reads the comment has to be one
click away from what it spun off.

When the investigation ends without a task — nothing reproduced, or the finding
is still a hypothesis — record the outcome in one line ("not reproduced on
<env>, no task opened") and stop there. Do not argue the decision inside the
ticket: the reader wants the state, not a rationale for the process.

#### d) Transition the ticket

If the ticket is currently at `Open` (or any status the workflow treats as
"not started") **and** the overlay provides a `start_progress` transition
ID, apply it first before moving to the target transition. Jira otherwise
rejects the direct jump.

```bash
transition_payload() {
  local tid="$1"
  jq -n --arg id "$tid" '{transition: {id: $id}}'
}

# If the ticket needs the intermediate step, fire it first.
if [[ "$current_status" == "Open" && -n "$start_progress_id" ]]; then
  curl --config "$JIRA_CURL_CONFIG" -X POST \
    -H "Content-Type: application/json" \
    "$JIRA_BASE_URL/rest/api/3/issue/$KEY/transitions" \
    --data "$(transition_payload "$start_progress_id")"
fi

# Then the target transition.
curl --config "$JIRA_CURL_CONFIG" -X POST \
  -H "Content-Type: application/json" \
  "$JIRA_BASE_URL/rest/api/3/issue/$KEY/transitions" \
  --data "$(transition_payload "$target_transition_id")"
```

Note the `jq -n --arg` builder — never hand-roll the JSON payload, even
when the only substituted value is an ID. If the overlay value ever
contained a `"` (unlikely but possible), interpolation would break the
body.

These two ids are the only transitions the plugin applies. The overlay may list
others (`block`, `mr_created`, `resolve`, …) for reference; a status the board
does not map to a column keeps the ticket in the sprint but hides it from the
board, which is what happened the one time an id was picked by hand. When a
fix is merged but not yet deployed, leave the ticket where it is.

### 5. If the fix requires a product-code change

Dispatch to `/jira:create` with the ticket key as the source. That command
handles the task creation, linking, and release wiring based on the
overlay's `task_creation`, `release_links`, and `source_ticket_link`
settings.

### 6. Output

Present a table of classified tickets and ask which one to start with.
