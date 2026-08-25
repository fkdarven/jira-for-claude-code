#!/usr/bin/env bash
# Regression tests for lib/jira-media.sh.
#
# Run from the plugin root:
#   bash plugins/jira/tests/test-jira-media.sh
#
# Everything here is offline: the one function that talks to Jira
# (jira_media_id) is exercised against a stubbed `curl` that replays a real
# 303 header block, so the redirect parsing and the token-leak guard are
# covered without a token or a network.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
plugin_src=$(cd "$script_dir/.." && pwd)
failures=0
total=0

# shellcheck source=../lib/jira-media.sh
source "$plugin_src/lib/jira-media.sh"

FAKE_TOKEN="eyJhbGciOiJIUzI1NiJ9.fake-signed-media-token-that-must-never-be-printed"
FAKE_UUID="a6a70b80-8b29-4e93-8120-ad1260a62b96"

check() {
  local title="$1" expected="$2" actual="$3"
  total=$((total + 1))
  if [[ "$expected" == "$actual" ]]; then
    printf "  PASS  %s\n" "$title"
  else
    failures=$((failures + 1))
    printf "  FAIL  %s\n" "$title"
    printf "        expected: %s\n" "$expected"
    printf "        actual:   %s\n" "$actual"
  fi
}

json_field() {  # json_field <json> <python expression over `d`>
  printf '%s' "$1" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print($2)
" 2>/dev/null
}

echo "jira-media tests"

# --- jira_adf_image -------------------------------------------------------

node=$(jira_adf_image "$FAKE_UUID" "shot.png" 520)
check "adf_image is a mediaSingle"        "mediaSingle" "$(json_field "$node" 'd["type"]')"
check "adf_image carries the media id"    "$FAKE_UUID"  "$(json_field "$node" 'd["content"][0]["attrs"]["id"]')"
check "adf_image pins collection to ''"   ""            "$(json_field "$node" 'd["content"][0]["attrs"]["collection"]')"
check "adf_image keeps the alt text"      "shot.png"    "$(json_field "$node" 'd["content"][0]["attrs"]["alt"]')"
check "adf_image sets the display width"  "520"         "$(json_field "$node" 'd["attrs"]["width"]')"
check "adf_image marks the width as px"   "pixel"       "$(json_field "$node" 'd["attrs"]["widthType"]')"

bare=$(jira_adf_image "$FAKE_UUID")
check "adf_image omits width when unset"  "False" "$(json_field "$bare" '"width" in d["attrs"]')"
check "adf_image omits alt when unset"    "False" "$(json_field "$bare" '"alt" in d["content"][0]["attrs"]')"

jira_adf_image >/dev/null 2>&1
check "adf_image without a media id exits 2" "2" "$?"

# A non-numeric width must not end up in the node as a string.
loose=$(jira_adf_image "$FAKE_UUID" "shot.png" "wide")
check "adf_image ignores a non-numeric width" "False" "$(json_field "$loose" '"width" in d["attrs"]')"

# --- jira_adf_file --------------------------------------------------------

filenode=$(jira_adf_file "$FAKE_UUID" "report.pdf")
check "adf_file is a mediaGroup"         "mediaGroup"  "$(json_field "$filenode" 'd["type"]')"
check "adf_file carries the media id"    "$FAKE_UUID"  "$(json_field "$filenode" 'd["content"][0]["attrs"]["id"]')"
check "adf_file keeps the alt text"      "report.pdf"  "$(json_field "$filenode" 'd["content"][0]["attrs"]["alt"]')"

jira_adf_file >/dev/null 2>&1
check "adf_file without a media id exits 2" "2" "$?"

# --- guards ---------------------------------------------------------------

jira_media_id "not-a-number" >/dev/null 2>&1
check "media_id rejects a non-numeric id" "2" "$?"

(
  unset JIRA_BASE_URL JIRA_CURL_CONFIG
  jira_media_id 123 >/dev/null 2>&1
)
check "media_id without bootstrap exits 2" "2" "$?"

(
  unset JIRA_BASE_URL JIRA_CURL_CONFIG
  jira_attach ISSUE-1 /tmp >/dev/null 2>&1
)
check "attach without bootstrap exits 2" "2" "$?"

export JIRA_BASE_URL="https://example.atlassian.net"
JIRA_CURL_CONFIG=$(mktemp)
export JIRA_CURL_CONFIG

jira_attach >/dev/null 2>&1
check "attach without arguments exits 2" "2" "$?"

jira_attach ISSUE-1 "/tmp/definitely-missing-$$.png" >/dev/null 2>&1
check "attach on a missing file exits 1" "1" "$?"

comma_file=$(mktemp -d)/"a,b.png"
: > "$comma_file"
err=$(jira_attach ISSUE-1 "$comma_file" 2>&1)
check "attach refuses a path with a comma" "1" "$(printf '%s' "$err" | grep -cF "cannot take a path containing")"
rm -rf "$(dirname "$comma_file")"

# --- redirect parsing, with curl stubbed ----------------------------------
# The real Location header carries a signed read token. The UUID must come
# out; the token must not appear on stdout.

curl() {
  cat <<EOF
HTTP/1.1 303 See Other
Server: AtlassianEdge
Location: https://api.media.atlassian.com/file/$FAKE_UUID/binary?token=$FAKE_TOKEN&client=2d29b611-6749-4b59-8c60-eb8ee752c3c3
Content-Length: 0

EOF
}

got=$(jira_media_id 46860)
check "media_id extracts the uuid from Location" "$FAKE_UUID" "$got"

total=$((total + 1))
if printf '%s' "$got" | grep -qF "$FAKE_TOKEN"; then
  failures=$((failures + 1))
  printf "  FAIL  media_id does not leak the signed media token\n"
else
  printf "  PASS  media_id does not leak the signed media token\n"
fi

# A 200 with no Location (some proxies inline the body) must fail loudly
# rather than print an empty id.
curl() { printf 'HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n'; }
jira_media_id 46860 >/dev/null 2>&1
check "media_id fails when there is no redirect" "1" "$?"

unset -f curl
rm -f "$JIRA_CURL_CONFIG"

echo
if (( failures > 0 )); then
  printf "FAILED: %d / %d\n" "$failures" "$total"
  exit 1
fi
printf "OK: %d / %d\n" "$total" "$total"
