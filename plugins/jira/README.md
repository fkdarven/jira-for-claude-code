# jira plugin

Claude Code plugin that automates Jira Cloud workflows: smart ticket lookup,
support-ticket triage, and creating technical tasks linked to releases.

The plugin itself is generic. All project keys, transition IDs, account IDs,
custom fields, epics, and workflow defaults live in a user overlay you
maintain in your own dotfiles — none are baked in.

## Commands

| Command                 | What it does |
|-------------------------|--------------|
| `/jira:auto <arg>`      | Router: fetch a ticket by key, list your open tickets, or dispatch to `routine` / `create`. |
| `/jira:routine`         | Triage open tickets in your support project: classify, investigate, comment, transition. |
| `/jira:create <arg>`    | Create a task in your sprint project, linked to a source ticket and a release. |

## Attachments and inline images

`lib/jira-media.sh` covers the one thing the Jira REST API makes awkward:
putting a screenshot inside a description or a comment. Source it after the
bootstrap and it handles the upload plus the media-id lookup the ADF `media`
node needs — the numeric attachment id the upload returns is *not* that id, and
using it gets you a bare `400 ATTACHMENT_VALIDATION_ERROR`.

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/bootstrap.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/jira-media.sh"

# attachmentId <TAB> mediaId <TAB> filename
jira_attach PROJ-123 ./shot.png

jira_adf_image "<mediaId>" "shot.png" 520   # mediaSingle node, 520px wide
jira_adf_file  "<mediaId>" "report.pdf"     # mediaGroup node — file card
```

The `jira-context` skill documents the full three-call sequence and the two
approaches that look like they should work and don't.

## Setup

One-time setup has two pieces: secrets (plugin `.env`) and user overlay
(`~/.claude/custom/jira.yaml`).

### 1. Secrets (plugin `.env`)

```bash
cd "${CLAUDE_PLUGIN_ROOT}"          # the jira plugin dir
cp .env.example .env
# Open .env and fill in the required values.
```

Required variables:

| Variable          | Source                                                   | Required |
|-------------------|----------------------------------------------------------|----------|
| `JIRA_BASE_URL`   | Your Jira Cloud URL, e.g. `https://org.atlassian.net`    | yes      |
| `JIRA_EMAIL`      | Your Atlassian account email                             | yes      |
| `JIRA_API_TOKEN`  | https://id.atlassian.com/manage-profile/security/api-tokens | yes   |

### 2. User overlay (`~/.claude/custom/jira.yaml`)

```bash
mkdir -p ~/.claude/custom
cp "${CLAUDE_PLUGIN_ROOT}/config.example.yaml" ~/.claude/custom/jira.yaml
# Fill it with your real Jira IDs.
```

The example file documents every required key. The critical ones:

- `self.jira_account_id` — your Atlassian account ID.
- `projects[]` — each project has a semantic `role` (`support`, `sprint`,
  `roadmap`, `other`). Commands reference projects by role, not by key.
- `transitions.<PROJECT_KEY>` — map semantic actions (`start_progress`,
  `staging`, `resolve`, etc.) to the numeric transition IDs of that project's
  workflow. Fetch IDs from `GET /rest/api/3/issue/{key}/transitions`.
- `accounts[]` — name→account ID mapping for assignment.
- `custom_fields.story_points` — the Jira custom field ID for SP.
- `epics[]` — common parent epics offered by `/jira:create`.
- `task_creation.summary_format` — template for titles, e.g.
  `"[{space}] {title}"`.
- `triage.categories` — classification tags used by `/jira:routine`.

### 3. Verify

Trigger any command; the bootstrap validates both files and aborts with a
clear message if anything is missing.

## How it finds things

The plugin never searches for config in alternate locations. Exactly:

- **Secrets:** `${CLAUDE_PLUGIN_ROOT}/.env` (the installed plugin directory).
- **Overlay:** `~/.claude/custom/jira.yaml`.

If either is missing or incomplete, the bootstrap aborts. There is no
fallback.

## Dependencies

- `bash` (Git Bash on Windows works).
- `python` with `pyyaml` — used by the bootstrap to validate the overlay's
  shape against `config.example.yaml`.
- `curl` — for every Jira API call.
- `yq` (optional) — nicer overlay reads; commands fall back to inline Python.

## Tests

```bash
bash plugins/jira/tests/test-bootstrap.sh
bash plugins/jira/tests/test-jira-media.sh
```

Both are offline: no token, no network. `test-jira-media.sh` stubs `curl` with
a recorded 303 so the redirect parsing — and the guard against echoing the
signed media token — stay covered.
