---
command: auto
description: Smart router — interprets what you want to do in Jira
---

## Bootstrap (required first step)

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/bootstrap.sh"
trap 'rm -f "$JIRA_CURL_CONFIG"' EXIT
```

If the bootstrap fails, surface its error verbatim and stop.

Then read `${CLAUDE_PLUGIN_ROOT}/skills/jira-context/SKILL.md` for the API
reference and the overlay-reading pattern.

## Argument

`$ARGUMENTS`

## Routing table

| Argument | Dispatch |
|----------|----------|
| Issue key matching `<KEY>-<N>` where `<KEY>` exists in `projects[]`    | Fetch the ticket via API, show summary (title, status, priority, **issuetype**, assignee, description), ask what to do |
| `routine` or `triage`                                                  | `/jira:routine` |
| `create ...`                                                           | `/jira:create` |
| (empty)                                                                | List your open tickets in the configured source project via JQL: `project = <support_key> AND assignee = currentUser() AND statusCategory != Done ORDER BY status ASC, priority DESC, created DESC` |
| anything else                                                          | Interpret as intent; if ambiguous, ask one clarifying question |

## Resolving "the source project"

Read the overlay once:

```bash
support_key=$("$JIRA_PYTHON" -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
role = d.get("triage", {}).get("source_project_role", "support")
print(next((p["key"] for p in d.get("projects", []) if p.get("role") == role), ""))
' < "$JIRA_OVERLAY_FILE")

if [[ -z "$support_key" ]]; then
  printf "ERROR: no project in %s has role matching triage.source_project_role.\n" "$JIRA_OVERLAY_FILE" >&2
  exit 2
fi
```

`triage.source_project_role` is the canonical answer; the literal string
`support` is only the fallback when the overlay does not name a role.
