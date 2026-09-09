---
name: jira-context
description: How to call Jira Cloud's API and how the plugin resolves user-specific project/workflow IDs
---

## Plugin bootstrap (ALWAYS run first)

Every command in this plugin begins by sourcing the shared bootstrap, which
loads and validates `.env` and the user overlay. If either is missing or
incomplete, the bootstrap aborts with a clear message and the skill must stop.

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/bootstrap.sh"
```

After it returns successfully, the following variables are in scope:

| Variable            | Source                       | Purpose |
|---------------------|------------------------------|---------|
| `JIRA_BASE_URL`     | `.env`                       | Base URL for every API call (no trailing slash). |
| `JIRA_EMAIL`        | `.env`                       | Reference only for building prompts / display; never pass on a curl CLI. |
| `JIRA_API_TOKEN`    | `.env`                       | Raw secret. Never reference directly on a CLI — use `$JIRA_CURL_CONFIG`. |
| `JIRA_OVERLAY_FILE` | bootstrap-exported path      | Path to the user overlay YAML. |
| `JIRA_PYTHON`       | bootstrap-detected           | Python interpreter verified to have PyYAML. |
| `JIRA_CURL_CONFIG`  | bootstrap-exported path      | 600-perm file containing the Authorization header. Pass to curl via `--config "$JIRA_CURL_CONFIG"`. |
| `JIRA_RULES_FILE`   | bootstrap-exported path      | Team policy file, exported only when `~/.claude/custom/jira.rules.md` exists. Unset when it does not. |

Never hardcode a project key, transition ID, account ID, custom field ID,
or link type in a command. Read it from the overlay.

## House rules live next to the overlay

Team policy that sits on top of the mechanics (which status a ticket ends in, how the
customer-facing answer is split, who owns a derived issue) is not versioned with the
plugin. It lives in `~/.claude/custom/jira.rules.md`; when that file exists the
bootstrap exports its path as `JIRA_RULES_FILE`. Read it right after the bootstrap,
before any comment, link or transition, and follow it over any default described here.
Secrets follow the same idea: `~/.claude/custom/jira.env` is read first, so a version
bump never needs the `.env` copied into the new cache directory.

## Reading the overlay

Pipe the overlay file into Python via stdin — no path interpolation, no
quote-escaping, no OS-specific path conversion. Works identically on Linux,
macOS, and Git Bash on Windows:

```bash
support_key=$("$JIRA_PYTHON" -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
role = d.get("triage", {}).get("source_project_role", "support")
print(next((p["key"] for p in d.get("projects", []) if p.get("role") == role), ""))
' < "$JIRA_OVERLAY_FILE")
```

Commands should always resolve project keys **by role**, not by literal
key. The role to look up comes from `triage.source_project_role` (or the
relevant `*.default_project_role` for task creation). A literal default
like `support` is only the fallback when the overlay does not declare a
role explicitly.

## API reference

- **Base URL:** `$JIRA_BASE_URL`
- **Auth:** `curl --config "$JIRA_CURL_CONFIG" ...` — the Authorization
  header is read from a 600-perm file, never from a CLI argument.

### Endpoints this plugin uses

| Purpose             | Method + path |
|---------------------|---------------|
| Search issues (JQL) | `POST /rest/api/3/search/jql` (GET is deprecated, returns `total: 0`) |
| Issue detail        | `GET /rest/api/3/issue/{key}` (use `?expand=changelog` for history) |
| Create issue        | `POST /rest/api/3/issue` |
| Update issue        | `PUT /rest/api/3/issue/{key}` |
| List transitions    | `GET /rest/api/3/issue/{key}/transitions` |
| Apply transition    | `POST /rest/api/3/issue/{key}/transitions` with `{"transition":{"id":"N"}}` |
| Add comment         | `POST /rest/api/3/issue/{key}/comment` (body in ADF) |
| Create issue link   | `POST /rest/api/3/issueLink` |
| Current user        | `GET /rest/api/3/myself` |
| List boards         | `GET /rest/agile/1.0/board?projectKeyOrId={KEY}` |
| List sprints        | `GET /rest/agile/1.0/board/{boardId}/sprint?state=active,future` |
| Add issues to sprint| `POST /rest/agile/1.0/sprint/{sprintId}/issue` with `{"issues":["KEY-1"]}` (204, max 50 keys) |
| Upload attachment   | `POST /rest/api/3/issue/{key}/attachments` (multipart, header `X-Atlassian-Token: no-check`) |
| Resolve a media id  | `GET /rest/api/3/attachment/content/{id}` — answers 303; the UUID is in the `Location` path |

### Sprints are not set at creation

The Sprint custom field shows up on the create screen, but it is read-only
there: passing it in `POST /rest/api/3/issue` is silently ignored and the issue
lands in the backlog. Putting an issue in a sprint is always a second call, to
the Agile API above. Which projects need it, and which board answers for each,
come from the overlay's `sprints` block — never hardcode a board or sprint ID,
and never create a sprint on the user's behalf.

A project with more than one scrum board is common (a live board next to an
`(OLD)` one). When discovery returns several, ask instead of guessing: the
wrong board means a sprint nobody looks at, which is the same as the backlog.

### Issue keys in a body are links, never bare text

Every issue key that shows up in a description or a comment — the tasks a triage
comment spun off, a related ticket, a release — is written as a clickable link
to `$JIRA_BASE_URL/browse/<KEY>`. A key rendered as plain or bold text costs the
reader a copy, a switch to the search box and a paste before they can see what
the comment is talking about.

The `link` mark composes with `strong`, so a key stays emphasised *and* becomes
clickable:

```json
{"type":"text","text":"PROJ-123",
 "marks":[{"type":"link","attrs":{"href":"https://your.atlassian.net/browse/PROJ-123"}},
          {"type":"strong"}]}
```

Build the `href` from `$JIRA_BASE_URL` — never from a hardcoded host.

Never guess the base URL either, not even for a link written by hand in a report.
A short slug that looks like the obvious tenant can belong to somebody else: for one
site, `<slug>.atlassian.net` is a live Cloud instance of an unrelated company, while
theirs is `<slug>-<product>.atlassian.net`. Pointing an authenticated call at the wrong
tenant hands that company a working Basic header with the user's API token. The value
in `.env` is the only source.

For a key that stands on its own line, `inlineCard` is the richer form: Jira
resolves it into a smart card carrying summary, status and assignee.

```json
{"type":"inlineCard","attrs":{"url":"https://your.atlassian.net/browse/PROJ-123"}}
```

`inlineCard` is a standalone inline node and accepts no marks, so it cannot be
bolded and cannot sit inside a sentence you also want emphasised. Inside a
sentence, use the `text` + `link` form above.

Writing the link does not replace the issue link. A body that names a key must
also carry the real relationship via `POST /rest/api/3/issueLink`, or the panel
of linked items stays empty and only someone who reads the whole comment finds
out the ticket produced anything.

### Comments and descriptions: write markdown, convert with `lib/jira-adf.py`

Nothing in this plugin hand-rolls ADF beyond a one-paragraph wrapper. A body is
written to a file in the markdown subset the converter understands and turned
into ADF by:

```bash
"$JIRA_PYTHON" "${CLAUDE_PLUGIN_ROOT}/lib/jira-adf.py" \
  --base-url "$JIRA_BASE_URL" --projects "SUP,ENG" --wrap comment body.md   # {"body": doc}
"$JIRA_PYTHON" "${CLAUDE_PLUGIN_ROOT}/lib/jira-adf.py" --wrap description body.md   # bare doc
"$JIRA_PYTHON" "${CLAUDE_PLUGIN_ROOT}/lib/jira-adf.py" --projects "SUP,ENG" --keys body.md   # keys cited
```

Both panel markers start a block, so `[[/PANEL]]` needs a blank line before it, the
same as the opening marker. Without it the closer is read as panel content: the panel
never closes, every following block is swallowed by it, and `[[/PANEL]]` shows up as
text. It raises no error, because the document is valid, just entirely inside the
panel. Validate the ADF before the POST or PUT rather than after: counting the top
level nodes and checking the type of the first costs one line and catches this before
it reaches the ticket.

Subset: paragraphs, `- ` bullets, `1. ` ordered lists, `#` headings, fenced code,
`` `code` ``, `**bold**`, `[text](url)`, and panels `[[SUCCESS]] … [[/PANEL]]`
(also INFO, NOTE, WARNING, ERROR). Every bare key of a `--projects` project
becomes a link to `$JIRA_BASE_URL/browse/<KEY>` on its own; `[**KEY**](url)`
composes bold with the link. The green `success` panel is where the
customer-facing part of a comment goes; whether it opens with a label
paragraph, and in which words, is policy and comes from the rules file.
`--keys` feeds the issue-link step: a key a comment cites is also linked for
real.

### A relay bot in the panel: two comments, mention on the first line

A team can put a bot on the ticket that forwards the customer-facing part onward,
relaying everything below its own mention in the comment and nothing above it. Where
that is in play, the answer to the customer is a comment of its own holding only the
green panel, with the bot mention `@[Display Name](accountId)` as the first thing
inside the panel, alone on its first line, and no label paragraph, which the bot would
relay too. The technical part (cause, fix) is a separate comment, posted first, with no
mention at all. So `/jira:comment` runs twice, and the duplicate check does not protect
a panel-only body: look at the ticket before the second post.

Which label triggers this, and which account the bot is, are policy. They live in the
rules file, not here.

### Editing and deleting a comment

A ticket commented in steps can be consolidated afterwards. Edit a posted comment with
`PUT /rest/api/3/issue/{key}/comment/{id}` (same shape as the POST). Delete with
`DELETE /rest/api/3/issue/{key}/comment/{id}`; there is no undo, so save every original
body to a file first and post the replacement before removing anything.

Whether a ticket ends with a single consolidated comment, and what a closure without a
task reads like, is policy. The rules file decides; this skill states no default.

### Transitions come from the overlay, and the destination must be on the board

The plugin applies two transition ids and no other: `start_progress` (when the
ticket is still at Open) and `triage.target_transition`. Other ids in the overlay
are documentation. Before moving, `/jira:comment` reads the board configuration
(`GET /rest/agile/1.0/board/{id}/configuration`) and refuses a destination status
that no column maps: such a ticket keeps its sprint but disappears from the board.

### Link direction: the inwardIssue is the subject of the sentence

Jira applies the type's `outward` description **from the `inwardIssue` to the
`outwardIssue`**. Posting `inwardIssue: A, outwardIssue: B` on a type whose `outward`
is "implements" reads *A implements B*. So when a task implements a release, the task
is the `inwardIssue` and the release is the `outwardIssue`, which renders "implements
RELEASE-KEY" on the task's page.

The POST answers 201 either way, and a symmetric type such as "Relates" hides the
mistake entirely. The only check that separates a correct link from an inverted one is
reading it back from the task's side:

```bash
curl -s --config "$JIRA_CURL_CONFIG" "$JIRA_BASE_URL/rest/api/3/issue/$KEY?fields=issuelinks" \
  | jq -r '.fields.issuelinks[] | if .outwardIssue then "\(.type.outward) \(.outwardIssue.key)" else "\(.type.inward) \(.inwardIssue.key)" end'
```

To undo an inverted link: `DELETE /rest/api/3/issueLink/{id}`, then post it swapped.

### Fields that are not on the create screen answer 400

Before sending a field on creation, confirm it exists on the create screen with
`GET /rest/api/3/issue/createmeta/<PROJECT>/issuetypes/<id>`. A field that is valid on
the issue but absent from that screen answers 400 ("cannot be set, it is not on the
appropriate screen"). `versions` and `fixVersions` are the usual pair to get wrong,
because both are valid on the issue and typically only one is on the screen.

This matters most for a service account that can only write on creation: when
`GET /issue/KEY` answers 404 for it, "create then edit" breaks, so everything the
ticket needs has to travel in the POST.

### Attachments and inline images

Neither a file nor a picture in the body can ride along in
`POST /rest/api/3/issue`. An illustrated description is always three calls:

1. `POST /rest/api/3/issue` — create the issue, description without media.
2. `POST /rest/api/3/issue/{key}/attachments` — multipart upload, one call per
   file, with the header `X-Atlassian-Token: no-check`.
3. `PUT /rest/api/3/issue/{key}` — rewrite the description, this time with a
   media node pointing at what you just uploaded.

Step 3 is where it bites. The ADF `media` node addresses the file by its Media
Services UUID, **not** by the numeric `id` the upload returns; hand it the
numeric id and Jira answers `400 ATTACHMENT_VALIDATION_ERROR` with an empty
`errors` object and no further hint. No attachment endpoint carries that UUID
in its JSON. It surfaces in exactly one place — the `Location` of the 303 that
`GET /rest/api/3/attachment/content/{id}` answers with:

    https://api.media.atlassian.com/file/<uuid>/binary?token=...

`lib/jira-media.sh` wraps all of that. Source it after the bootstrap:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/bootstrap.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/jira-media.sh"

# one line per file: attachmentId <TAB> mediaId <TAB> filename
jira_attach PROJ-123 ./shot.png ./report.pdf
```

| Function | What it does |
|----------|--------------|
| `jira_attach ISSUE_KEY FILE...`          | Uploads and resolves each file, printing `attachmentId`, `mediaId` and the basename as TSV. |
| `jira_media_id ATTACHMENT_ID`            | Numeric attachment id → Media Services UUID. |
| `jira_adf_image MEDIA_ID [ALT] [WIDTH]`  | Prints the `mediaSingle` node for an image. |
| `jira_adf_file MEDIA_ID [ALT]`           | Prints the `mediaGroup` node — the file card Jira shows for anything it cannot render inline. |

Building the nodes by hand is fine too; the shapes are:

```json
{"type":"mediaSingle","attrs":{"layout":"center","width":520,"widthType":"pixel"},
 "content":[{"type":"media","attrs":{"type":"file","id":"<uuid>","collection":"","alt":"shot.png"}}]}
```

`collection` has to be there and has to be the empty string. The file's own
pixel dimensions are optional; display size lives on the wrapper, as
`mediaSingle.attrs.width` plus `widthType: "pixel"`. Omit it and Jira draws the
image at roughly 250px, which is too small to read a screenshot. The same node
works unchanged in a comment body — a picture in a comment costs the upload
plus the ordinary `POST /issue/{key}/comment`.

Two dead ends, both already tested — don't spend the round trip:

- `media` with `type: "external"` and a `url` is accepted by the API and
  survives the round trip in the stored ADF, but the issue view renders it as
  **Preview unavailable**. There is no one-call illustrated create.
- `PUT /rest/api/2/issue/{key}` with wiki markup (`!file.png!`) does work —
  Jira resolves the filename and writes the UUID itself. But it replaces the
  entire description with the converted markup, so it only makes sense when
  you were overwriting the description anyway.

The `token` in that `Location` header is a live short-lived read credential for
the file. Parse the UUID out of the path and discard the rest: never print,
log, or persist the header itself.

Every request must include the auth header from `$JIRA_CURL_CONFIG`:

```bash
curl --config "$JIRA_CURL_CONFIG" -X POST \
  -H "Content-Type: application/json" \
  "$JIRA_BASE_URL/rest/api/3/search/jql" \
  --data "$jql_body"
```

### Conventions the plugin follows

- JQL uses `assignee = currentUser()` whenever possible — avoid hardcoding
  an account ID unless you need it for assignment.
- Comments must be ADF, not plain text. Wrap as:
  ```json
  {"body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"..."}]}]}}
  ```
- Transitions are identified by semantic names in the overlay
  (`start_progress`, `staging`, `resolve`, `block`, `mr_created`,
  `stop_progress`) and resolved to numeric IDs via
  `transitions.<PROJECT_KEY>.<name>`.
- When a ticket's project isn't in `transitions`, fetch IDs live from
  `/rest/api/3/issue/{key}/transitions` and suggest the user add them to
  the overlay.

## Secret handling

`JIRA_API_TOKEN` is a secret. Treat it like a password:

- **Never pass it on any command line.** Not via `-u "$JIRA_EMAIL:$JIRA_API_TOKEN"`,
  not via `-H`, not as a positional arg. On POSIX systems every
  command-line argument is visible to any local user via `ps aux`.
- **Always use `--config "$JIRA_CURL_CONFIG"`.** The bootstrap builds the
  Basic-auth header, base64-encodes it, and writes it into a 600-perm
  file; curl reads it from disk, which is not visible in process listings.
- **Never echo, print, or log the token value.** Not even in dry-run
  output.
- **Never write it to a snapshot, log file, or report.**
- **Clean up the curl config when the skill is done.** Add to the end of
  each command's flow:

  ```bash
  rm -f "$JIRA_CURL_CONFIG"
  ```

  or register it as an EXIT trap at the top of a long-running skill.

## What the plugin never does

- Never writes to a project that isn't declared in `projects[]`.
- Never closes a ticket directly to Done unless the user explicitly asks.
  The default "I'm done with this" transition is whatever the overlay's
  `triage.target_transition` names (typically a QA/staging step).
- Never infers missing overlay values from guesses — a missing key is
  always an abort with a specific error.
