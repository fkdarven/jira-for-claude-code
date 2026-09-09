# jira-for-claude-code

A Claude Code marketplace with one plugin: `jira`, for day-to-day Jira Cloud
work: looking a ticket up, triaging a support queue, opening technical tasks
linked to a release, posting a consolidated comment and moving the ticket.

Nothing about any particular Jira instance is baked into it. Project keys,
transition IDs, account IDs, custom fields, epics and workflow defaults all
come from a user overlay you keep in your own dotfiles, so the same plugin
works against any Jira Cloud site.

## Commands

| Command | What it does |
|---------|--------------|
| `/jira:auto <arg>` | Router: fetch a ticket by key, list your open tickets, or dispatch to `routine` / `create`. |
| `/jira:routine` | Triage the open tickets in your support project: classify, investigate, comment, transition. |
| `/jira:create <arg>` | Create a task in your sprint project, linked to a source ticket and a release. |
| `/jira:comment <key> <file.md> [flag]` | Post a comment from a markdown file, link every key it cites, and optionally move the ticket through the overlay's transition. |
| `/jira:roadmap <arg>` | Create a roadmap item under a version epic in your roadmap project. |

## Install

Add the marketplace and enable the plugin in `~/.claude/settings.json`:

```json
{
  "enabledPlugins": {
    "jira@jira-for-claude-code": true
  },
  "extraKnownMarketplaces": {
    "jira-for-claude-code": {
      "source": {
        "source": "git",
        "url": "https://github.com/fkdarven/jira-for-claude-code.git"
      }
    }
  }
}
```

Then do the setup: `~/.claude/custom/jira.env` with your credentials,
`~/.claude/custom/jira.yaml` with your Jira IDs, and optionally
`~/.claude/custom/jira.rules.md` with your team's policy. All three are
documented in [`plugins/jira/README.md`](plugins/jira/README.md).

## Layout

```
.claude-plugin/
  marketplace.json              <- marketplace manifest
plugins/
  jira/
    .claude-plugin/plugin.json  <- plugin manifest
    commands/                   <- /jira:auto, /jira:routine, /jira:create,
                                   /jira:comment, /jira:roadmap
    lib/bootstrap.sh            <- config loading + validation, curl auth
    lib/jira-adf.py             <- markdown subset -> Atlassian Document Format
    lib/jira-media.sh           <- attachments and inline images
    skills/jira-context/        <- how to call the API, and the gotchas
    tests/                      <- offline: no token, no network
```

## Tests

```bash
for f in plugins/jira/tests/test-*.sh; do bash "$f"; done
```

All three suites are offline: no token, no network.

## License

MIT — see [LICENSE](LICENSE).
