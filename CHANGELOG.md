# Changelog

Versions before 1.7.1 are documented by their annotated git tags
(`git tag -n20 -l 'jira--v*'`).

## [1.7.2] - 2026-09-09

### Changed

- Team policy is no longer written into the plugin. The skill and the commands
  keep the mechanics (the green panel exists, `PUT` edits a comment, `DELETE`
  removes one with no undo, transitions come from the overlay) and state no
  default for what is a team's decision: how a customer-facing answer opens,
  whether a ticket ends with one consolidated comment, what a closure without a
  task reads like, when `resolve` is the right ending. Those come from
  `~/.claude/custom/jira.rules.md` via `JIRA_RULES_FILE`.
- `/jira:comment`, `/jira:create`, `/jira:roadmap` and `/jira:routine` now say,
  in their bootstrap step, to read `JIRA_RULES_FILE` when it is set and to
  follow it over any default the command describes. `JIRA_RULES_FILE` is also
  listed in the skill's variable table.
- Examples use neutral identifiers: `ROADMAP-186`, `ROADMAP-190`, `ROADMAP-125`
  in the commands, and clearly illustrative transition ids in
  `config.example.yaml`.
- `/jira:auto` states that its keyword lists are examples, not a closed
  vocabulary.

### Fixed

- The repository README listed three of the five commands, omitted
  `lib/jira-adf.py` from the layout, and ran two of the three test suites. It
  now matches `plugin.json`.
- The plugin README's setup commands relied on `${CLAUDE_PLUGIN_ROOT}`, which is
  substituted inside a command's text but never exported to the user's shell, so
  they could not be pasted into a terminal. They resolve the installed plugin
  directory instead.

## [1.7.1] - 2026-09-09

### Added

- Credentials are read from `~/.claude/custom/jira.env` first, with
  `${CLAUDE_PLUGIN_ROOT}/.env` kept as a fallback, so a version bump no longer
  leaves the secrets file behind in the previous cache directory. Nothing to
  migrate: an existing `.env` in the plugin root keeps working.
- Optional house rules file at `~/.claude/custom/jira.rules.md`. When it exists
  the bootstrap exports its path as `JIRA_RULES_FILE`; when it does not, the
  variable is cleared, so a stale value inherited from the environment cannot
  point a command at a file the plugin never validated.
- Skill, link direction. Jira applies a type's `outward` description from the
  `inwardIssue` to the `outwardIssue`, the POST answers 201 either way, and a
  symmetric type hides the mistake. The section carries the read-back that
  separates a correct link from an inverted one and the `DELETE` that undoes it.
- Skill, panel markers. `[[/PANEL]]` needs a blank line before it, the same as
  the opening marker. Without it the closer is read as panel content, the panel
  never closes, and no error is raised because the document is still valid.
- Skill, base URL. Never guess it, not even for a link written by hand: a short
  slug that looks like the obvious tenant can be a live Cloud instance of an
  unrelated company, and an authenticated call sent there hands that company a
  working Basic header. The secrets file is the only source.
- Skill, editing and deleting a comment, with the warning that deletion has no
  undo.

### Changed

- The create-screen section is generic mechanics: confirm a field exists with
  `GET /rest/api/3/issue/createmeta/<PROJECT>/issuetypes/<id>` before sending
  it, because a field valid on the issue but absent from that screen answers
  400. `versions` and `fixVersions` are the usual pair to get wrong.
