---
command: comment
description: Post a consolidated comment on a ticket, link every key it cites, and (optionally) move the ticket through the overlay's target transition
---

## Bootstrap (required first step)

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/bootstrap.sh"
trap 'rm -f "$JIRA_CURL_CONFIG"' EXIT
```

If the bootstrap fails, surface its error verbatim and stop.

When `JIRA_RULES_FILE` is set, read that file before any comment, link or
transition, and follow it over any default this command describes.

## Argument

`$ARGUMENTS`

Shape: `<KEY> <path-to-body.md> [staging|close|done|resolve] [force]`

- `<KEY>`: an issue in one of the overlay's `projects[]`.
- `<path-to-body.md>`: the comment, written in the markdown subset `lib/jira-adf.py`
  understands (paragraphs, `- ` bullets, `` `code` ``, `**bold**`, `[text](url)`,
  `@[Display Name](accountId)` for a mention that actually pings the person,
  fenced code, and `[[SUCCESS]] … [[/PANEL]]` for the client-facing panel). Write
  the body to a file first; never inline it in the command line.
- `staging` / `close` / `done`: after commenting, apply the overlay's
  `triage.target_transition` (with `start_progress` first when the ticket is still
  at Open).
- `resolve`: after commenting, apply the overlay's `transitions.<PROJECT>.resolve`
  (with `start_progress` first when the ticket is still at Open). Only when the
  user said, in this conversation, to resolve this ticket, and only when the rules
  file does not reserve that ending for something narrower. Never infer it from the
  body of the comment.
- When the rules file puts a relay bot on the ticket, run the command twice: first the
  technical body, then a body that is only the `[[SUCCESS]]` panel, with the bot mention
  alone on its first line and no label paragraph (see the skill). The duplicate check
  does not cover a panel-only body.
- No other transition is ever applied by this command.
- `force`: post even if a comment with the same opening paragraph already exists.

## Why this command exists

The transition that follows a comment comes from the overlay, not from a
transition id picked by hand, and the destination is checked against the board
first. That rule was being re-implemented in ad-hoc scripts, and one of those
scripts moved a ticket into a status the board has no column for, so the card
vanished from the sprint.
This command is the only path for "comment and move".

## Flow

### 1. Resolve overlay values

```bash
read_overlay() { "$JIRA_PYTHON" -c "$1" < "$JIRA_OVERLAY_FILE"; }

project_keys=$(read_overlay '
import sys, yaml
d = yaml.safe_load(sys.stdin)
print(",".join(p["key"] for p in d.get("projects", [])))
')
link_type=$(read_overlay '
import sys, yaml
print(yaml.safe_load(sys.stdin).get("source_ticket_link", {}).get("link_type", "Relates"))
')
```

`KEY`'s project must be in `$project_keys`; otherwise abort ("project not
declared in the overlay") — the plugin never writes to a project it does not know.

For the transition (only when the argument asks for it; `TRANSITION_ARG` is the
third word of the argument, empty when absent), resolve as `/jira:routine` does:

```bash
project=${KEY%%-*}
target_name=$(read_overlay 'import sys, yaml; print(yaml.safe_load(sys.stdin).get("triage", {}).get("target_transition", ""))')
# When the argument was `resolve`, the target is the overlay's resolve
# transition instead; everything after this line (offered check, board mapping,
# start_progress first) is the same.
[[ "$TRANSITION_ARG" == "resolve" ]] && target_name="resolve"
target_id=$(read_overlay "import sys, yaml; print((yaml.safe_load(sys.stdin).get('transitions', {}).get('$project') or {}).get('$target_name', ''))")
start_id=$(read_overlay "import sys, yaml; print((yaml.safe_load(sys.stdin).get('transitions', {}).get('$project') or {}).get('start_progress', ''))")
board_id=$(read_overlay "import sys, yaml; print(((yaml.safe_load(sys.stdin).get('sprints', {}) or {}).get('boards') or {}).get('$project', ''))")
```

Abort if `target_id` is empty and a transition was requested: the overlay has
no `transitions.<PROJECT>.<target_transition>` entry, and guessing an id is
exactly what this command forbids.

### 2. Convert the body and check for a duplicate

```bash
body_json=$("$JIRA_PYTHON" "${CLAUDE_PLUGIN_ROOT}/lib/jira-adf.py" \
  --base-url "$JIRA_BASE_URL" --projects "$project_keys" --wrap comment "$BODY_FILE")
marker=$("$JIRA_PYTHON" "${CLAUDE_PLUGIN_ROOT}/lib/jira-adf.py" --marker "$BODY_FILE")

existing=$(curl -s --config "$JIRA_CURL_CONFIG" \
  "$JIRA_BASE_URL/rest/api/3/issue/$KEY/comment?maxResults=100")
```

Flatten every existing comment body to plain text (walk `content[].text`) and,
if one contains `$marker`, stop with "comment already posted (id N)" unless the
argument carried `force`. The marker is the first paragraph of the body, so a
re-run of the same file is a no-op.

Show the user the rendered plain text of the first two blocks and the panel (if
any) before posting, so a wrong file is caught here and not in the ticket.

### 3. Post the comment

```bash
curl --config "$JIRA_CURL_CONFIG" -X POST \
  -H "Content-Type: application/json" \
  "$JIRA_BASE_URL/rest/api/3/issue/$KEY/comment" \
  --data "$body_json"
```

A 201 returns the comment id; keep it for the report.

### 4. Link every key the comment cites

The converter already turned each bare key into a clickable link in the text.
The panel of linked items still needs the real relationship:

```bash
cited=$("$JIRA_PYTHON" "${CLAUDE_PLUGIN_ROOT}/lib/jira-adf.py" --projects "$project_keys" --keys "$BODY_FILE")
links=$(curl -s --config "$JIRA_CURL_CONFIG" "$JIRA_BASE_URL/rest/api/3/issue/$KEY?fields=issuelinks")

for other in $cited; do
  [[ "$other" == "$KEY" ]] && continue
  if printf '%s' "$links" | jq -e --arg k "$other" \
       '.fields.issuelinks[] | select((.outwardIssue.key // .inwardIssue.key) == $k)' >/dev/null; then
    continue   # already linked, any type
  fi
  payload=$(jq -n --arg type "$link_type" --arg a "$KEY" --arg b "$other" \
    '{type: {name: $type}, inwardIssue: {key: $a}, outwardIssue: {key: $b}}')
  curl --config "$JIRA_CURL_CONFIG" -X POST -H "Content-Type: application/json" \
    "$JIRA_BASE_URL/rest/api/3/issueLink" --data "$payload"
done
```

`Relates` is symmetric, so direction does not matter here. Keys of projects the
overlay does not declare are left as plain text and not linked.

### 5. Transition (only if asked)

Read the current status and the transitions Jira offers **now**; never reuse an
id from memory:

```bash
status=$(curl -s --config "$JIRA_CURL_CONFIG" "$JIRA_BASE_URL/rest/api/3/issue/$KEY?fields=status" | jq -r '.fields.status.name')
offered=$(curl -s --config "$JIRA_CURL_CONFIG" "$JIRA_BASE_URL/rest/api/3/issue/$KEY/transitions")
```

First make sure the target transition is offered from where the ticket is now.
Jira only lists the transitions that are valid from the current status, so an
empty result means "already there, or someone moved it meanwhile" and the answer
is to report the current status, not to try another id:

```bash
to_status=$(printf '%s' "$offered" | jq -r --arg id "$target_id" '.transitions[] | select(.id == $id) | .to.id')
[[ -n "$to_status" ]] || { echo "transition $target_id ($target_name) is not offered from status '$status'; leaving the ticket as is"; exit 0; }
```

Then make sure the destination is visible on the board. A status the board does
not map to a column keeps the ticket in the sprint but hides it from everyone
looking at the board:

```bash
if [[ -n "$board_id" ]]; then
  mapped=$(curl -s --config "$JIRA_CURL_CONFIG" "$JIRA_BASE_URL/rest/agile/1.0/board/$board_id/configuration" \
    | jq -r '[.columnConfig.columns[].statuses[].id] | index($ARGS.positional[0]) != null' --args "$to_status")
  [[ "$mapped" == "true" ]] || { echo "status $to_status of transition $target_id is not mapped on board $board_id; not moving"; exit 2; }
fi
```

Then apply, in order, exactly what `/jira:routine` step (d) applies:

```bash
transition_payload() { jq -n --arg id "$1" '{transition: {id: $id}}'; }

if [[ "$status" == "Open" && -n "$start_id" ]]; then
  curl --config "$JIRA_CURL_CONFIG" -X POST -H "Content-Type: application/json" \
    "$JIRA_BASE_URL/rest/api/3/issue/$KEY/transitions" --data "$(transition_payload "$start_id")"
fi
curl --config "$JIRA_CURL_CONFIG" -X POST -H "Content-Type: application/json" \
  "$JIRA_BASE_URL/rest/api/3/issue/$KEY/transitions" --data "$(transition_payload "$target_id")"
```

When the argument did not ask for a transition, the ticket stays where it is: a
fix that is merged but not yet deployed stays In Progress.

### 6. Report

Re-read the ticket and print: comment id, keys linked (and which already were),
status before → after, and the ticket URL `$JIRA_BASE_URL/browse/$KEY`.
