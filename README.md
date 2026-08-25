# jira-for-claude-code

A Claude Code marketplace with one plugin: `jira`, for day-to-day Jira Cloud
work — looking a ticket up, triaging a support queue, and opening technical
tasks linked to a release.

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

Then do the two-part setup — an `.env` with your credentials and an overlay
with your Jira IDs. Both are documented in
[`plugins/jira/README.md`](plugins/jira/README.md).

## Layout

```
.claude-plugin/
  marketplace.json              <- marketplace manifest
plugins/
  jira/
    .claude-plugin/plugin.json  <- plugin manifest
    commands/                   <- /jira:auto, /jira:routine, /jira:create
    lib/bootstrap.sh            <- config loading + validation, curl auth
    lib/jira-media.sh           <- attachments and inline images
    skills/jira-context/        <- how to call the API, and the gotchas
    tests/                      <- offline: no token, no network
```

## Tests

```bash
bash plugins/jira/tests/test-bootstrap.sh
bash plugins/jira/tests/test-jira-media.sh
```

## License

MIT — see [LICENSE](LICENSE).
