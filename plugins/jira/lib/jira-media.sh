#!/usr/bin/env bash
# Jira plugin — attachments and inline images.
#
# Source AFTER lib/bootstrap.sh, which is what exports JIRA_BASE_URL,
# JIRA_CURL_CONFIG and JIRA_PYTHON:
#
#     source "${CLAUDE_PLUGIN_ROOT}/lib/bootstrap.sh"
#     source "${CLAUDE_PLUGIN_ROOT}/lib/jira-media.sh"
#
# Why this file exists
# --------------------
# A picture inside a description or a comment is not a field you can fill in
# on POST /rest/api/3/issue. The ADF `media` node addresses the file by its
# Media Services UUID, which:
#
#   * only exists once the file has been uploaded to that specific issue;
#   * is NOT the numeric id the attachment endpoints return — feeding that id
#     to a media node fails with 400 ATTACHMENT_VALIDATION_ERROR;
#   * appears in exactly one public place: the Location header of the 303 that
#     GET /rest/api/3/attachment/content/{id} answers with, of the form
#     https://api.media.atlassian.com/file/<uuid>/binary?token=...
#
# So an illustrated description is always three calls: create, upload, rewrite.
#
# The token in that Location is a short-lived read credential. jira_media_id
# parses out the UUID and nothing else — never print or store the raw header.
#
# Functions
# ---------
#   jira_attach ISSUE_KEY FILE...            upload; one TSV line per file:
#                                            attachmentId <TAB> mediaId <TAB> filename
#   jira_media_id ATTACHMENT_ID              print the Media Services UUID
#   jira_adf_image MEDIA_ID [ALT] [WIDTH]    ADF mediaSingle node (image)
#   jira_adf_file  MEDIA_ID [ALT]            ADF mediaGroup node (file card)

_jira_media_ready() {
  local missing=()
  [[ -n "${JIRA_BASE_URL:-}" ]]    || missing+=("JIRA_BASE_URL")
  [[ -n "${JIRA_CURL_CONFIG:-}" ]] || missing+=("JIRA_CURL_CONFIG")
  if (( ${#missing[@]} )); then
    printf "ERROR (jira plugin): %s not set — source lib/bootstrap.sh first.\n" \
      "${missing[*]}" >&2
    return 2
  fi
}

_jira_py() { printf '%s' "${JIRA_PYTHON:-python3}"; }

# jira_media_id ATTACHMENT_ID
#
# Resolves the numeric attachment id to the Media Services UUID that ADF
# media nodes expect.
jira_media_id() {
  local att_id="${1:-}"
  if [[ ! "$att_id" =~ ^[0-9]+$ ]]; then
    printf "ERROR (jira plugin): jira_media_id needs a numeric attachment id, got: '%s'\n" \
      "$att_id" >&2
    return 2
  fi
  _jira_media_ready || return 2

  # -o /dev/null keeps the binary out of stdout; -D - dumps the headers so the
  # redirect can be read. curl does not follow it, which is what we want: the
  # UUID is in the Location path, and the request never has to be spent.
  local headers uuid
  headers=$(curl -sS -o /dev/null -D - --config "$JIRA_CURL_CONFIG" \
    "$JIRA_BASE_URL/rest/api/3/attachment/content/$att_id") || {
    printf "ERROR (jira plugin): could not reach attachment %s.\n" "$att_id" >&2
    return 1
  }

  uuid=$(printf '%s' "$headers" | tr -d '\r' \
    | sed -n 's|^[Ll]ocation:.*/file/\([0-9a-fA-F-]\{36\}\)/.*|\1|p')
  uuid=${uuid%%$'\n'*}

  if [[ -z "$uuid" ]]; then
    printf "ERROR (jira plugin): no media id in the redirect for attachment %s.\n" "$att_id" >&2
    printf "  Expected a 303 to https://api.media.atlassian.com/file/<uuid>/binary\n" >&2
    printf "  Check that the attachment exists and that the token can read its issue.\n" >&2
    return 1
  fi
  printf '%s\n' "$uuid"
}

# jira_attach ISSUE_KEY FILE...
#
# Uploads each file and prints "attachmentId<TAB>mediaId<TAB>filename".
# Non-image files get a media id too — use it with jira_adf_file.
jira_attach() {
  local issue="${1:-}"
  shift 2>/dev/null || true
  if [[ -z "$issue" || $# -eq 0 ]]; then
    printf "ERROR (jira plugin): usage: jira_attach ISSUE_KEY FILE [FILE...]\n" >&2
    return 2
  fi
  _jira_media_ready || return 2

  local f resp att_id media_id
  for f in "$@"; do
    if [[ ! -f "$f" ]]; then
      printf "ERROR (jira plugin): file not found: %s\n" "$f" >&2
      return 1
    fi
    # curl's -F splits its argument on "," and reads ";" as a parameter
    # separator, so those two characters in a path silently mangle the upload.
    case "$f" in
      *,*|*\;*)
        printf "ERROR (jira plugin): curl -F cannot take a path containing ',' or ';': %s\n" "$f" >&2
        printf "  Copy the file to a plain path first.\n" >&2
        return 1
        ;;
    esac

    resp=$(curl -sS --config "$JIRA_CURL_CONFIG" -X POST \
      -H "X-Atlassian-Token: no-check" \
      -F "file=@$f" \
      "$JIRA_BASE_URL/rest/api/3/issue/$issue/attachments") || {
      printf "ERROR (jira plugin): upload of %s failed at the transport level.\n" "$f" >&2
      return 1
    }

    # A successful upload answers with a JSON array; every error shape Jira
    # returns here is an object, so the type check doubles as the error check.
    att_id=$(printf '%s' "$resp" | "$(_jira_py)" -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
if not isinstance(data, list) or not data:
    sys.exit(1)
print(data[0]["id"])
') || {
      printf "ERROR (jira plugin): upload of %s rejected by Jira: %s\n" "$f" "$resp" >&2
      return 1
    }

    media_id=$(jira_media_id "$att_id") || return 1
    printf '%s\t%s\t%s\n' "$att_id" "$media_id" "$(basename "$f")"
  done
}

# jira_adf_image MEDIA_ID [ALT] [DISPLAY_WIDTH_PX]
#
# Prints one ADF mediaSingle node, ready to drop into a description or comment
# body. DISPLAY_WIDTH_PX is how wide Jira draws it, not the file's own size —
# omit it and Jira falls back to roughly 250px, which is small for a screenshot.
jira_adf_image() {
  local media_id="${1:-}" alt="${2:-}" width="${3:-}"
  if [[ -z "$media_id" ]]; then
    printf "ERROR (jira plugin): usage: jira_adf_image MEDIA_ID [ALT] [DISPLAY_WIDTH_PX]\n" >&2
    return 2
  fi
  JIRA_ADF_ID="$media_id" JIRA_ADF_ALT="$alt" JIRA_ADF_W="$width" \
  "$(_jira_py)" -c '
import json, os

attrs = {"type": "file", "id": os.environ["JIRA_ADF_ID"], "collection": ""}
alt = os.environ.get("JIRA_ADF_ALT", "")
if alt:
    attrs["alt"] = alt

single = {"type": "mediaSingle", "attrs": {"layout": "center"}}
width = os.environ.get("JIRA_ADF_W", "")
if width.isdigit():
    single["attrs"]["width"] = int(width)
    single["attrs"]["widthType"] = "pixel"

single["content"] = [{"type": "media", "attrs": attrs}]
print(json.dumps(single, ensure_ascii=False))
'
}

# jira_adf_file MEDIA_ID [ALT]
#
# Prints one ADF mediaGroup node — the file card Jira shows for things it
# cannot render inline (PDF, .md, .csv, archives).
jira_adf_file() {
  local media_id="${1:-}" alt="${2:-}"
  if [[ -z "$media_id" ]]; then
    printf "ERROR (jira plugin): usage: jira_adf_file MEDIA_ID [ALT]\n" >&2
    return 2
  fi
  JIRA_ADF_ID="$media_id" JIRA_ADF_ALT="$alt" \
  "$(_jira_py)" -c '
import json, os

attrs = {"type": "file", "id": os.environ["JIRA_ADF_ID"], "collection": ""}
alt = os.environ.get("JIRA_ADF_ALT", "")
if alt:
    attrs["alt"] = alt

print(json.dumps({"type": "mediaGroup", "content": [{"type": "media", "attrs": attrs}]},
                 ensure_ascii=False))
'
}
