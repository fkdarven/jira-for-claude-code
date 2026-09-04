---
command: roadmap
description: Create a roadmap item under a version epic in the roadmap project
---

## Bootstrap (required first step)

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/bootstrap.sh"
trap 'rm -f "$JIRA_CURL_CONFIG"' EXIT
```

If the bootstrap fails, surface its error verbatim and stop.

## Argument

`$ARGUMENTS`

Free form. What the flow needs is a **version** (`3.10`), a **summary**, and optionally a **path to a markdown body**. Anything missing is asked for. Called with no argument at all, the flow stops after step 2 and prints the version epics that exist, which is also how you discover what the roadmap is carrying.

## Why this command exists

`/jira:create` is a sprint task: it lives in the sprint project, links a source ticket and a release, and lands on a board. A roadmap item is none of that. It lives in the roadmap project, hangs off a **version epic** as its parent, and never goes near a sprint. Sharing one flow would mean branching almost all of it, so this is a separate command.

## Flow

### 1. Resolve the roadmap project

From the overlay, `roadmap_project_key` is the `projects[]` entry whose `role` matches `roadmap.default_project_role` (default: `roadmap`), and `issuetype` is `roadmap.default_issuetype` (default: `Story`).

```bash
read -r roadmap_project_key issuetype <<<"$("$JIRA_PYTHON" -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
cfg = d.get("roadmap", {}) or {}
role = cfg.get("default_project_role", "roadmap")
key = next((p["key"] for p in d.get("projects", []) if p.get("role") == role), "")
print(key, cfg.get("default_issuetype", "Story"))
' < "$JIRA_OVERLAY_FILE")"

if [[ -z "$roadmap_project_key" ]]; then
  printf "ERROR: no projects[] entry with the roadmap role in %s.\nSee %s/config.example.yaml.\n" \
    "$JIRA_OVERLAY_FILE" "$CLAUDE_PLUGIN_ROOT" >&2
  exit 2
fi
```

### 2. Resolve the version epic

The parent is an Epic whose summary is the version, like `3.10.0`. The user types `3.10` or `3.10.0` and both have to land on the same epic, so match by prefix and decide on the number of hits.

```bash
jql=$(jq -n --arg p "$roadmap_project_key" \
  '{jql: ("project = " + $p + " AND issuetype = Epic ORDER BY summary DESC"),
    maxResults: 50, fields: ["summary", "status"]}')

epics=$(curl -s --config "$JIRA_CURL_CONFIG" -X POST \
  -H "Content-Type: application/json" \
  "$JIRA_BASE_URL/rest/api/3/search/jql" --data "$jql")

matches=$(printf '%s' "$epics" | jq -r --arg v "$version" \
  '[.issues[] | select(.fields.summary | startswith($v))]
   | map("\(.key)\t\(.fields.summary)") | .[]')
```

Three outcomes, and only one of them proceeds:

- **Exactly one match**: that is the parent.
- **No match**: print every epic that came back, with key and summary, and stop. Never create the epic. A version that does not exist yet is a conversation, not a side effect of running a command.
- **More than one**: `3.1` matching `3.1.0` and `3.10.0` is the normal case, not an edge one. Show the matches and ask which. Do not guess by "shortest" or "newest".

Called with no version, print the list and stop here.

### 3. Collect summary and body

The **summary** is a short name, in the voice the roadmap already uses for its items. Look at the sibling items under the epic before writing one.

The **body** is optional and comes from a file, never inline on the command line. It is written in the markdown subset `lib/jira-adf.py` understands, and converted with:

```bash
description=$("$JIRA_PYTHON" "$CLAUDE_PLUGIN_ROOT/lib/jira-adf.py" \
  --wrap description "$body_file")
```

A roadmap item often opens with a panel stating the problem it solves. The closing marker of a panel **must start its own block**, which means a blank line before it:

```
[[INFO]]
The one-line statement of the problem.

[[/PANEL]]

The rest of the description.
```

Without that blank line the marker is read as panel content, the panel never closes, and every following block is swallowed into it. Nothing errors: you get a well-formed document with the whole body inside the panel and `[[/PANEL]]` showing as text.

### 4. Create the issue

Build the payload with `jq -n --arg`, never by string interpolation: a summary or body can legitimately carry quotes, backslashes and newlines.

```bash
body=$(jq -n \
  --arg project   "$roadmap_project_key" \
  --arg summary   "$summary" \
  --arg issuetype "$issuetype" \
  --arg parent    "$epic_key" \
  --argjson desc  "${description:-null}" \
  '{
    fields: ({
      project:   { key: $project },
      summary:   $summary,
      issuetype: { name: $issuetype },
      parent:    { key: $parent }
    } + (if $desc == null then {} else {description: $desc} end))
  }')

curl --config "$JIRA_CURL_CONFIG" -X POST \
  -H "Content-Type: application/json" \
  "$JIRA_BASE_URL/rest/api/3/issue" --data "$body"
```

`--argjson` with a `null` fallback keeps an item without a body from crashing `jq`, and omits the field instead of sending an empty description.

### 5. What this command never does

- **No sprint.** A roadmap item is not sprint work. The Agile call that `/jira:create` makes has no place here.
- **No transition.** The item is born at the project's initial status and stays there.
- **No epic creation.** Step 2 stops when the version has no epic.
- **No release link.** The version epic already says which release the item belongs to; a link would say it twice.

### 6. Confirm

Print the created key as a browse URL, the epic it hangs from with its summary, and whether a body was sent. Then stop: nothing here moves a board.

```
PUBLISHER-190  https://your.atlassian.net/browse/PUBLISHER-190
epic           PUBLISHER-125 (3.10.0)
description    sent (panel + 5 sections)
```
