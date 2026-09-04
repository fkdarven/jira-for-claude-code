#!/usr/bin/env bash
# Regression tests for the jira plugin bootstrap.
#
# Run from the plugin root:
#   bash plugins/jira/tests/test-bootstrap.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
plugin_src=$(cd "$script_dir/.." && pwd)
failures=0
total=0

REAL_BASE="https://example.atlassian.net"
REAL_EMAIL="reviewer@example.com"
REAL_TOKEN="fake-jira-token-for-tests-length-192-chars-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

make_plugin_root() {
  local root
  root=$(mktemp -d)
  cp -r "$plugin_src"/{skills,commands,lib,.claude-plugin,.env.example,config.example.yaml,README.md} "$root/"
  cat > "$root/.env" <<EOF
JIRA_BASE_URL=$REAL_BASE
JIRA_EMAIL=$REAL_EMAIL
JIRA_API_TOKEN=$REAL_TOKEN
EOF
  chmod 600 "$root/.env"
  printf '%s' "$root"
}

valid_overlay() {
  cat <<'YAML'
self:
  email: "reviewer@example.com"
  jira_account_id: "test-account-id"
projects:
  - key: "SUP"
    name: "Support"
    role: "support"
  - key: "ENG"
    name: "Engineering"
    role: "sprint"
  - key: "ROAD"
    name: "Roadmap"
    role: "roadmap"
transitions:
  SUP:
    start_progress: 4
    staging: 741
    resolve: 5
    block: 781
    mr_created: 711
    stop_progress: 301
accounts:
  - name: "Reviewer"
    email: "reviewer@example.com"
    jira_account_id: "test-account-id"
custom_fields:
  story_points: "customfield_10016"
epics:
  - key: "ENG-1"
    name: "Example Epic"
task_creation:
  default_project_role: "sprint"
  default_issuetype: "Task"
  summary_format: "[{space}] {title}"
  common_spaces: ["Example"]
sprints:
  add_to_active_sprint_roles: ["sprint"]
  boards: {}
release_links:
  link_type: "Polaris work item link"
  release_project_role: "roadmap"
source_ticket_link:
  link_type: "Relates"
triage:
  source_project_role: "support"
  target_transition: "staging"
  categories: ["bug"]
  ssh_config_file: ""
  ssh_requires_vpn: false
  host_pattern: ""
YAML
}

make_home_with_overlay() {
  local home
  home=$(mktemp -d)
  mkdir -p "$home/.claude/custom"
  if [[ $# -ge 1 ]]; then
    printf '%s' "$1" > "$home/.claude/custom/jira.yaml"
  else
    valid_overlay > "$home/.claude/custom/jira.yaml"
  fi
  printf '%s' "$home"
}

run_case() {
  local title="$1"
  local expected_exit="$2"
  local expected_stderr_substr="$3"
  local root="$4"
  local home="$5"
  total=$((total + 1))

  local stderr_file
  stderr_file=$(mktemp)
  CLAUDE_PLUGIN_ROOT="$root" HOME="$home" \
    bash "$root/lib/bootstrap.sh" 2> "$stderr_file"
  local actual_exit=$?

  local ok=1
  if [[ "$actual_exit" != "$expected_exit" ]]; then ok=0; fi
  if [[ -n "$expected_stderr_substr" ]] && ! grep -Fq -- "$expected_stderr_substr" "$stderr_file"; then
    ok=0
  fi

  if (( ok )); then
    printf "  PASS  %s\n" "$title"
  else
    failures=$((failures + 1))
    printf "  FAIL  %s\n" "$title"
    printf "        expected exit=%s, got %s\n" "$expected_exit" "$actual_exit"
    if [[ -n "$expected_stderr_substr" ]]; then
      printf "        expected stderr to contain: %s\n" "$expected_stderr_substr"
    fi
    printf "        stderr was:\n"
    sed 's/^/          /' "$stderr_file"
  fi

  rm -f "$stderr_file"
  rm -rf "$root" "$home"
}

echo "jira bootstrap tests"

# Case 1 — happy path.
root=$(make_plugin_root)
home=$(make_home_with_overlay)
run_case "happy path exits 0" 0 "" "$root" "$home"

# Case 2 — missing .env.
root=$(make_plugin_root)
rm -f "$root/.env"
home=$(make_home_with_overlay)
run_case "missing .env reports the expected path" 2 "missing secrets file" "$root" "$home"

# Case 3 — required var empty.
root=$(make_plugin_root)
printf 'JIRA_BASE_URL=\nJIRA_EMAIL=\nJIRA_API_TOKEN=\n' > "$root/.env"
home=$(make_home_with_overlay)
run_case "empty required vars listed by name" 2 "JIRA_API_TOKEN" "$root" "$home"

# Case 4 — missing overlay.
root=$(make_plugin_root)
home=$(mktemp -d)
run_case "missing overlay reports the expected path" 2 "missing user overlay" "$root" "$home"

# Case 5 — empty user-defined container (transitions: {}). Test fixtures use
# only awk/sed rather than a YAML library so the tests do not depend on
# PyYAML being installed under any specific Python binary.
root=$(make_plugin_root)
bad=$(valid_overlay | awk '
  /^transitions:/ { print "transitions: {}"; skip=1; next }
  skip && /^[^[:space:]]/ { skip=0 }
  !skip { print }
')
home=$(make_home_with_overlay "$bad")
run_case "empty transitions caught by user-defined-container check" 2 "transitions (expected non-empty" "$root" "$home"

# Case 6 — missing nested key (drop task_creation.summary_format).
root=$(make_plugin_root)
bad=$(valid_overlay | awk '/summary_format:/ { next } { print }')
home=$(make_home_with_overlay "$bad")
run_case "missing nested key listed as task_creation.summary_format" 2 "task_creation.summary_format" "$root" "$home"

# Case 7 — bash -x must not leak the token.
root=$(make_plugin_root)
home=$(make_home_with_overlay)
debug_out=$(mktemp)
CLAUDE_PLUGIN_ROOT="$root" HOME="$home" \
  bash -x "$root/lib/bootstrap.sh" > "$debug_out" 2>&1
total=$((total + 1))
if grep -qF "$REAL_TOKEN" "$debug_out"; then
  failures=$((failures + 1))
  printf "  FAIL  bash -x does not leak JIRA_API_TOKEN\n"
  printf "        token appeared %s times in trace\n" "$(grep -cF "$REAL_TOKEN" "$debug_out")"
else
  printf "  PASS  bash -x does not leak JIRA_API_TOKEN\n"
fi
rm -f "$debug_out"
rm -rf "$root" "$home"

# Case 8 — curl config exported with an Authorization header. POSIX mode
# bits (chmod 600) are not asserted because MSYS/Git Bash cannot enforce
# them; asserting existence + content keeps the test portable.
root=$(make_plugin_root)
home=$(make_home_with_overlay)
total=$((total + 1))
got=$(
  CLAUDE_PLUGIN_ROOT="$root" HOME="$home" bash -c '
    source "$1/lib/bootstrap.sh"
    [[ -f "$JIRA_CURL_CONFIG" ]] || { echo "missing file"; exit 1; }
    head -1 "$JIRA_CURL_CONFIG"
    rm -f "$JIRA_CURL_CONFIG"
  ' _ "$root" 2>/dev/null
)
if printf '%s' "$got" | grep -q "Authorization: Basic "; then
  printf "  PASS  curl config file carries an Authorization header\n"
else
  failures=$((failures + 1))
  printf "  FAIL  curl config file carries an Authorization header\n"
  printf "        got: %s\n" "$got"
fi
rm -rf "$root" "$home"

# Case 9 — CLAUDE_PLUGIN_ROOT unset: the harness substitutes the variable in
# the command text but does not export it, so bootstrap must derive the root
# from its own path and export it.
root=$(make_plugin_root)
home=$(make_home_with_overlay)
total=$((total + 1))
got=$(
  HOME="$home" env -u CLAUDE_PLUGIN_ROOT bash -c '
    source "$1/lib/bootstrap.sh"
    printf "%s" "$CLAUDE_PLUGIN_ROOT"
    rm -f "$JIRA_CURL_CONFIG"
  ' _ "$root" 2>/dev/null
)
if [[ "$got" == "$root" ]]; then
  printf "  PASS  bootstrap derives CLAUDE_PLUGIN_ROOT from its own path when unset\n"
else
  failures=$((failures + 1))
  printf "  FAIL  bootstrap derives CLAUDE_PLUGIN_ROOT from its own path when unset\n"
  printf "        expected %s, got: %s\n" "$root" "$got"
fi
rm -rf "$root" "$home"

echo
if (( failures > 0 )); then
  printf "FAILED: %d / %d\n" "$failures" "$total"
  exit 1
fi
printf "OK: %d / %d\n" "$total" "$total"
