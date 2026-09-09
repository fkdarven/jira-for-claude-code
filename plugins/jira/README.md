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
| `/jira:comment <KEY> <body.md> [staging] [force]` | Post a consolidated comment (markdown in, ADF out), link every key it cites, and optionally move the ticket through the overlay's target transition after checking the board has a column for it. |
| `/jira:roadmap <version> <summary> [body.md]` | Create a roadmap item under the version epic in your roadmap project. No sprint, no transition, no release link; the epic already says which release it belongs to. Run it bare to list the version epics that exist. |

## Comments: markdown in, ADF out

`lib/jira-adf.py` converts a markdown subset (paragraphs, bullets, code, bold,
links, `@[Display Name](accountId)` mentions, fenced code, `[[SUCCESS]] … [[/PANEL]]`
panels) into ADF, turning bare
issue keys of your projects into links. `/jira:comment` and `/jira:routine` use
it; so should anything else that writes a body. Tests: `tests/test-jira-adf.sh`.

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

One-time setup has two required pieces, secrets
(`~/.claude/custom/jira.env`) and user overlay
(`~/.claude/custom/jira.yaml`), plus an optional third one, house rules
(`~/.claude/custom/jira.rules.md`). All three live outside the plugin
directory, so a version bump never leaves them behind.

### 1. Secrets (`~/.claude/custom/jira.env`)

`${CLAUDE_PLUGIN_ROOT}` is substituted inside a command's text but is not
exported to your shell, so resolve the installed plugin directory once:

```bash
plugin_dir=$(ls -d ~/.claude/plugins/cache/jira-for-claude-code/jira/* | sort -V | tail -1)

mkdir -p ~/.claude/custom
cp "$plugin_dir/.env.example" ~/.claude/custom/jira.env
chmod 600 ~/.claude/custom/jira.env
# Open the file and fill in the required values.
```

`${CLAUDE_PLUGIN_ROOT}/.env` is still read when `~/.claude/custom/jira.env`
is absent, which keeps installs from before 1.7.1 working. It sits inside the
versioned plugin directory, so it has to be copied by hand on every upgrade.

Required variables:

| Variable          | Source                                                   | Required |
|-------------------|----------------------------------------------------------|----------|
| `JIRA_BASE_URL`   | Your Jira Cloud URL, e.g. `https://org.atlassian.net`    | yes      |
| `JIRA_EMAIL`      | Your Atlassian account email                             | yes      |
| `JIRA_API_TOKEN`  | https://id.atlassian.com/manage-profile/security/api-tokens | yes   |

### 2. User overlay (`~/.claude/custom/jira.yaml`)

```bash
cp "$plugin_dir/config.example.yaml" ~/.claude/custom/jira.yaml
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

### 3. House rules (`~/.claude/custom/jira.rules.md`, optional)

Team policy that sits on top of the mechanics, which status a ticket ends in,
how a customer-facing answer is split, who owns a derived issue, does not
belong in a versioned plugin. Write it in that file and the bootstrap exports
the path as `JIRA_RULES_FILE`; the `jira-context` skill reads it right after
the bootstrap and follows it over any default the skill documents. When the
file is absent, `JIRA_RULES_FILE` is unset and the documented defaults apply.

### 4. Verify

Trigger any command; the bootstrap validates both files and aborts with a
clear message if anything is missing.

## How it finds things

The plugin reads config from fixed paths, never from a search. Exactly:

- **Secrets:** `~/.claude/custom/jira.env`, and `${CLAUDE_PLUGIN_ROOT}/.env`
  when the first one is absent. Those two, in that order, and nowhere else.
- **Overlay:** `~/.claude/custom/jira.yaml`.
- **House rules:** `~/.claude/custom/jira.rules.md`, optional, exported as
  `JIRA_RULES_FILE` when present.

If the secrets file or the overlay is missing or incomplete, the bootstrap
aborts and names the paths it looked at.

## Dependencies

- `bash` (Git Bash on Windows works).
- `python` with `pyyaml` — used by the bootstrap to validate the overlay's
  shape against `config.example.yaml`.
- `curl` — for every Jira API call.
- `yq` (optional) — nicer overlay reads; commands fall back to inline Python.

## Tests

From this directory:

```bash
for f in tests/test-*.sh; do bash "$f"; done
```

All three are offline: no token, no network. `test-jira-media.sh` stubs `curl`
with a recorded 303 so the redirect parsing, and the guard against echoing the
signed media token, stay covered. `test-bootstrap.sh` covers the order the
secrets file is looked up in and the `JIRA_RULES_FILE` export.
