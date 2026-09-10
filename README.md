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

## Releasing

The app resolves an installed plugin by `cache/<marketplace>/<plugin>/<version>`,
not by the `installPath` recorded in `~/.claude/plugins/installed_plugins.json`.
Version and cache directory are coupled: bump the version field alone and the app
goes looking for a directory that does not exist, then reinstalls on its own from
the *committed* source, not from your working tree.

A release is:

1. Bump `version` in `plugins/jira/.claude-plugin/plugin.json` and in the plugin's
   entry in `.claude-plugin/marketplace.json`, and add the `CHANGELOG.md` entry.
2. Build the matching cache directory from the commit (`git archive HEAD`), not
   from the working tree, carrying the previous version's `.in_use` marker over.
3. Point `installed_plugins.json` at it, setting `installPath`, `version` and
   `gitCommitSha`, keeping a timestamped backup of the file.
4. Tag with `claude plugin tag --push -m "jira %s: <subject>" plugins/jira`. It
   validates `plugin.json` against the marketplace entry and writes an annotated
   `jira--v<version>` tag on HEAD. A release here is a tag plus a changelog entry;
   no GitHub release object is published, and `v1.4.1`, tagged by hand before the
   convention, stays as it is.

Two things about the previous version's directory. Live sessions were handed the
plugin as `--plugin-dir <path>` (`pgrep -af claude` shows it), so removing that
directory drops the plugin inside them; keep it until those sessions end. And a
command added by the bump only exists in a session started after it.

### Two manifest mistakes, both silent

- The manifest belongs at `plugins/<name>/.claude-plugin/plugin.json`. Left at the
  plugin root, the loader falls back to the directory basename, and since the cache
  directory is named after the version, every skill shows up twice, once as
  `<version>:<skill>`.
- A skill has to be a **directory** holding a `SKILL.md`. Declaring
  `skills: ["./skills/<name>.md"]` brings the plugin up as `✘ failed to load` and
  the skill is never loaded, while the commands keep working, so nothing looks
  broken from the outside.

Verify instead of assuming: `claude plugin list` prints `✔ enabled` or
`✘ failed to load` with the error, `claude plugin validate <path>` checks a
manifest, and `claude plugin details <name>` lists the components, so `Skills (0)`
on a plugin that ships a skill means the manifest is wrong.

## License

MIT — see [LICENSE](LICENSE).
