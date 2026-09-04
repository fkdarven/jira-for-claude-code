#!/usr/bin/env python3
"""Markdown-ish text -> Atlassian Document Format (ADF), for comments and descriptions.

    python3 "${CLAUDE_PLUGIN_ROOT}/lib/jira-adf.py" --base-url "$JIRA_BASE_URL" \
        --projects SUP,ENG --wrap comment body.md > body.json
    python3 "${CLAUDE_PLUGIN_ROOT}/lib/jira-adf.py" --projects SUP,ENG --keys body.md

Supported input (the subset a ticket comment needs, nothing more):

    paragraphs            blank-line separated; soft-wrapped lines are joined with a space
    - bullet lists        every line of the block starts with "- "
    1. ordered lists      every line of the block starts with "<n>. "
    ## headings           1 to 6 "#" (rarely wanted in a comment; there for descriptions)
    ```lang code```       fenced code block, blank lines inside are kept
    `code`  **bold**      inline marks
    [text](url)           link; [**text**](url) composes bold with the link
    PROJ-123              a bare issue key of one of --projects becomes a link to
                          <base-url>/browse/PROJ-123 (bold is kept when it is inside **...**)
    [[SUCCESS]] ... [[/PANEL]]
                          panel; the opening marker starts a block and the panel absorbs
                          every following block until [[/PANEL]]. Kinds: SUCCESS (green,
                          the client-facing answer), INFO, NOTE, WARNING, ERROR.
                          BOTH markers start a block, so [[/PANEL]] needs a blank line
                          before it. Glued to the previous paragraph it is read as panel
                          content: the panel never closes, everything after is swallowed
                          into it, and the marker shows up as text. No error is raised.

--wrap comment  prints {"body": <doc>}     (POST /rest/api/3/issue/{key}/comment)
--wrap description prints <doc>            (fields.description in create/update)
--keys          prints, one per line, the distinct issue keys the text mentions
                (for the issue-link step: every key a comment cites is also linked).

Standard library only, so it runs with whatever python3 the bootstrap picked.
"""

import argparse
import json
import re
import sys

PANELS = {
    "[[SUCCESS]]": "success",
    "[[INFO]]": "info",
    "[[NOTE]]": "note",
    "[[WARNING]]": "warning",
    "[[ERROR]]": "error",
}
PANEL_CLOSE = "[[/PANEL]]"

TOKEN = re.compile(r"(`[^`]+`|@\[[^\]]+\]\([^)]+\)|\[[^\]]+\]\([^)]+\)|\*\*[^*]+\*\*)")
LINK = re.compile(r"^\[([^\]]+)\]\(([^)]+)\)$")
# @[Display Name](accountId) becomes an ADF mention node, which is what pings
# the person in Jira. A plain "@Name" stays text and pings nobody.
MENTION = re.compile(r"^@\[([^\]]+)\]\(([^)]+)\)$")
HEADING = re.compile(r"^(#{1,6})\s+(.*\S)\s*$")
ORDERED = re.compile(r"^\d+\.\s+")


def key_regex(projects):
    if not projects:
        return None
    alternatives = "|".join(re.escape(p) for p in projects)
    return re.compile(r"(?<![A-Z0-9-])((?:%s)-\d+)(?![A-Za-z0-9-])" % alternatives)


def text_node(text, marks):
    node = {"type": "text", "text": text}
    if marks:
        node["marks"] = list(marks)
    return node


def text_with_keys(text, marks, keyre, base_url):
    """Split plain text so every bare issue key becomes its own linked node."""
    if not keyre or not base_url:
        return [text_node(text, marks)]
    out = []
    pos = 0
    for match in keyre.finditer(text):
        if match.start() > pos:
            out.append(text_node(text[pos:match.start()], marks))
        key = match.group(1)
        out.append(text_node(key, marks + [{"type": "link", "attrs": {"href": f"{base_url}/browse/{key}"}}]))
        pos = match.end()
    if pos < len(text):
        out.append(text_node(text[pos:], marks))
    return out


def inline(text, keyre, base_url):
    out = []
    for part in TOKEN.split(text):
        if not part:
            continue
        link = LINK.match(part)
        mention = MENTION.match(part)
        if part.startswith("`") and part.endswith("`"):
            out.append(text_node(part[1:-1], [{"type": "code"}]))
        elif mention:
            name, account_id = mention.group(1), mention.group(2)
            out.append({"type": "mention", "attrs": {"id": account_id, "text": "@" + name}})
        elif link:
            label, href = link.group(1), link.group(2)
            marks = [{"type": "link", "attrs": {"href": href}}]
            if label.startswith("**") and label.endswith("**"):
                label = label[2:-2]
                marks.append({"type": "strong"})
            out.append(text_node(label, marks))
        elif part.startswith("**") and part.endswith("**"):
            out.extend(text_with_keys(part[2:-2], [{"type": "strong"}], keyre, base_url))
        else:
            out.extend(text_with_keys(part, [], keyre, base_url))
    return out


def paragraph(text, keyre, base_url):
    return {"type": "paragraph", "content": inline(text, keyre, base_url)}


def list_node(lines, kind, keyre, base_url):
    items = []
    for line in lines:
        stripped = line.strip()
        body = stripped[2:] if kind == "bulletList" else ORDERED.sub("", stripped, count=1)
        items.append({"type": "listItem", "content": [paragraph(body, keyre, base_url)]})
    node = {"type": kind, "content": items}
    if kind == "orderedList":
        node["attrs"] = {"order": 1}
    return node


def split_blocks(source):
    """Yield ('code', lang, text) or ('text', lines) blocks, honouring fences."""
    lines = source.splitlines()
    i = 0
    current = []
    while i < len(lines):
        line = lines[i]
        if line.lstrip().startswith("```"):
            if current:
                yield ("text", current)
                current = []
            lang = line.strip()[3:].strip()
            i += 1
            code = []
            while i < len(lines) and not lines[i].lstrip().startswith("```"):
                code.append(lines[i])
                i += 1
            yield ("code", lang, "\n".join(code))
            i += 1
            continue
        if not line.strip():
            if current:
                yield ("text", current)
                current = []
        else:
            current.append(line)
        i += 1
    if current:
        yield ("text", current)


def block_nodes(lines, keyre, base_url):
    """Convert one blank-line-delimited text block into ADF nodes."""
    stripped = [l.strip() for l in lines]
    if all(s.startswith("- ") for s in stripped):
        return [list_node(stripped, "bulletList", keyre, base_url)]
    if all(ORDERED.match(s) for s in stripped):
        return [list_node(stripped, "orderedList", keyre, base_url)]
    heading = HEADING.match(stripped[0]) if len(stripped) == 1 else None
    if heading:
        return [{"type": "heading", "attrs": {"level": len(heading.group(1))},
                 "content": inline(heading.group(2), keyre, base_url)}]
    return [paragraph(" ".join(stripped), keyre, base_url)]


def convert(source, base_url=None, projects=None):
    keyre = key_regex(projects or [])
    content = []
    panel = None
    for block in split_blocks(source):
        if block[0] == "code":
            node = {"type": "codeBlock", "content": [{"type": "text", "text": block[2]}]}
            if block[1]:
                node["attrs"] = {"language": block[1]}
            (panel["content"] if panel is not None else content).append(node)
            continue
        lines = block[1]
        first = lines[0].strip()
        if first == PANEL_CLOSE:
            panel = None
            rest = lines[1:]
            if not rest:
                continue
            lines = rest
            first = lines[0].strip()
        opened = None
        for marker, kind in PANELS.items():
            if first.startswith(marker):
                opened = kind
                remainder = first[len(marker):].strip()
                lines = ([remainder] if remainder else []) + lines[1:]
                break
        if opened:
            panel = {"type": "panel", "attrs": {"panelType": opened}, "content": []}
            content.append(panel)
            if not lines:
                continue
        target = panel["content"] if panel is not None else content
        target.extend(block_nodes(lines, keyre, base_url))
    return {"type": "doc", "version": 1, "content": content}


def mentioned_keys(source, projects):
    keyre = key_regex(projects or [])
    if not keyre:
        return []
    seen = []
    for match in keyre.finditer(source):
        if match.group(1) not in seen:
            seen.append(match.group(1))
    return seen


def plain_text(node):
    if isinstance(node, dict):
        return node.get("text", "") + "".join(plain_text(c) for c in node.get("content", []) or [])
    if isinstance(node, list):
        return "".join(plain_text(c) for c in node)
    return ""


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file", help="markdown-ish input, or - for stdin")
    parser.add_argument("--base-url", default="", help="Jira base URL, used to link bare issue keys")
    parser.add_argument("--projects", default="", help="comma-separated project keys whose issue keys become links")
    parser.add_argument("--wrap", choices=["comment", "description"], default="comment")
    parser.add_argument("--keys", action="store_true", help="print the issue keys mentioned and exit")
    parser.add_argument("--marker", action="store_true", help="print the plain text of the first paragraph and exit")
    args = parser.parse_args(argv)

    source = sys.stdin.read() if args.file == "-" else open(args.file, encoding="utf-8").read()
    projects = [p.strip() for p in args.projects.split(",") if p.strip()]

    if args.keys:
        for key in mentioned_keys(source, projects):
            print(key)
        return 0

    doc = convert(source, args.base_url.rstrip("/"), projects)

    if args.marker:
        for node in doc["content"]:
            if node["type"] == "paragraph":
                print(plain_text(node)[:120])
                return 0
        return 0

    payload = {"body": doc} if args.wrap == "comment" else doc
    json.dump(payload, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
