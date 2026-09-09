#!/usr/bin/env bash
# Jira plugin bootstrap.
#
# Loads and validates the two inputs the plugin requires:
#   1. ~/.claude/custom/jira.env (or ${CLAUDE_PLUGIN_ROOT}/.env) — API credentials.
#   2. ~/.claude/custom/jira.yaml       — user overlay with project/workflow IDs.
#
# Skills/commands source this at the top:
#
#     source "${CLAUDE_PLUGIN_ROOT}/lib/bootstrap.sh"
#
# On success, exports:
#   JIRA_BASE_URL        — API root
#   JIRA_EMAIL           — auth user (only read when building the curl config)
#   JIRA_API_TOKEN       — raw secret (never reference from a command line)
#   JIRA_OVERLAY_FILE    — path to the user overlay YAML
#   JIRA_PYTHON          — Python interpreter verified to have PyYAML
#   JIRA_CURL_CONFIG     — path to a 600-perm file with the Authorization
#                          header, pass to curl via `--config "$JIRA_CURL_CONFIG"`
#   JIRA_RULES_FILE      — path to ~/.claude/custom/jira.rules.md, exported only
#                          when that file exists (team policy, optional)
#
# On missing/invalid config, prints the exact paths and keys involved and
# exits with status 2.

set -eo pipefail

die() {
  printf "ERROR (jira plugin): %s\n" "$*" >&2
  exit 2
}

# The harness substitutes ${CLAUDE_PLUGIN_ROOT} inside the command text, but
# it does not export the variable to the shell that runs the command. So when
# it is missing, derive the plugin root from this file's own location
# (lib/bootstrap.sh lives one level below the plugin root) and export it for
# the rest of the command (jira-adf.py, jira-media.sh, .env lookups).
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  CLAUDE_PLUGIN_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) \
    || die "could not derive CLAUDE_PLUGIN_ROOT from ${BASH_SOURCE[0]}"
  export CLAUDE_PLUGIN_ROOT
fi

plugin_root="$CLAUDE_PLUGIN_ROOT"
plugin_name="jira"
# Secrets live outside the versioned cache so a version bump never orphans them:
# ~/.claude/custom/jira.env first, the plugin root .env as the legacy fallback.
env_file_custom="${HOME}/.claude/custom/${plugin_name}.env"
env_file_legacy="$plugin_root/.env"
env_file="$env_file_custom"
[[ -f "$env_file" ]] || env_file="$env_file_legacy"
rules_file="${HOME}/.claude/custom/${plugin_name}.rules.md"
env_example="$plugin_root/.env.example"
overlay_file="${HOME}/.claude/custom/${plugin_name}.yaml"
overlay_example="$plugin_root/config.example.yaml"

# ---------------------------------------------------------------------------
# 1. Pick a Python interpreter that actually has PyYAML available.
# ---------------------------------------------------------------------------
PY_WITH_YAML=""
for candidate in python3 python python3.12 python3.11 python3.10; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import yaml' >/dev/null 2>&1; then
    PY_WITH_YAML="$candidate"
    break
  fi
done
if [[ -z "$PY_WITH_YAML" ]]; then
  die "no Python interpreter with PyYAML found on PATH.
  Install PyYAML under the interpreter you use, e.g.:
    python3 -m pip install --user pyyaml
  or use a virtualenv / system package that includes it."
fi

# ---------------------------------------------------------------------------
# 2. The secrets file must exist (custom path first, plugin root as fallback).
# ---------------------------------------------------------------------------
if [[ ! -f "$env_file" ]]; then
  die "missing secrets file. Looked for, in order:
    $env_file_custom (preferred, survives a version bump)
    $env_file_legacy (legacy, inside the versioned plugin directory)
  Create the preferred one by copying the example:
    mkdir -p '${HOME}/.claude/custom'
    cp '$env_example' '$env_file_custom'
  Then fill in the required values."
fi
# House rules (team policy on top of the mechanics) are optional and live with the
# overlay. Always assign, so a stale value inherited from the environment cannot
# point a command at a file this plugin never validated.
if [[ -f "$rules_file" ]]; then
  export JIRA_RULES_FILE="$rules_file"
else
  unset JIRA_RULES_FILE
fi

# ---------------------------------------------------------------------------
# 3. Required vars = lines in .env.example with an empty value. Lines of the
#    form KEY=, KEY="", or KEY='' all mean "user must supply a real value".
#    Lines that ship a default (KEY=somevalue) are treated as optional.
# ---------------------------------------------------------------------------
required_vars=()
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue
  if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=[[:space:]]*(\"\"|\'\')?[[:space:]]*$ ]]; then
    required_vars+=("${BASH_REMATCH[1]}")
  fi
done < "$env_example"

_xt_was_on=""
case "$-" in *x*) _xt_was_on=1 ;; esac
{ set +x; } 2>/dev/null

set -a
# shellcheck disable=SC1090
. "$env_file"
set +a

missing_vars=()
for v in "${required_vars[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    missing_vars+=("$v")
  fi
done

[[ -n "$_xt_was_on" ]] && set -x
unset _xt_was_on

if (( ${#missing_vars[@]} )); then
  printf "ERROR (jira plugin): the following env vars are missing or empty in %s:\n" "$env_file" >&2
  for v in "${missing_vars[@]}"; do
    printf "  - %s\n" "$v" >&2
  done
  printf "See %s for documentation on each variable.\n" "$env_example" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# 4. User overlay must exist at the canonical path.
# ---------------------------------------------------------------------------
if [[ ! -f "$overlay_file" ]]; then
  die "missing user overlay: $overlay_file
  Create it by copying the example:
    mkdir -p '$(dirname "$overlay_file")'
    cp '$overlay_example' '$overlay_file'
  Then replace the placeholder IDs with your real Jira values."
fi

# ---------------------------------------------------------------------------
# 5. Validate the overlay against the example's shape. Overlay content is
#    passed via stdin (never interpolated into the script).
# ---------------------------------------------------------------------------
"$PY_WITH_YAML" -c '
import sys, yaml

example_path = sys.argv[1]

USER_DEFINED_CONTAINERS = {
    "transitions",   # keys are project codes, user-specific
}

# Blocks the example documents but the plugin works without, because every
# value in them has a default in the command that reads it. Without this,
# documenting a new optional block in the example would refuse to start for
# every overlay written before it.
OPTIONAL_BLOCKS = {
    "roadmap",       # /jira:roadmap defaults to role "roadmap" + issuetype "Story"
}

try:
    with open(example_path, encoding="utf-8") as f:
        example = yaml.safe_load(f) or {}
    overlay = yaml.safe_load(sys.stdin) or {}
except yaml.YAMLError as exc:
    print(f"ERROR (jira plugin): overlay is not valid YAML: {exc}", file=sys.stderr)
    sys.exit(2)
except OSError as exc:
    print(f"ERROR (jira plugin): cannot read overlay: {exc}", file=sys.stderr)
    sys.exit(2)

def missing_keys(ex, ov, path=""):
    problems = []
    if path in USER_DEFINED_CONTAINERS:
        if not isinstance(ov, dict) or not ov:
            problems.append(f"{path} (expected non-empty map of user-defined entries)")
        return problems
    if isinstance(ex, dict):
        if not isinstance(ov, dict):
            problems.append(path or "<root>")
            return problems
        for k, v in ex.items():
            child_path = f"{path}.{k}" if path else k
            if k not in ov:
                if child_path in OPTIONAL_BLOCKS:
                    continue
                problems.append(child_path)
            else:
                problems.extend(missing_keys(v, ov[k], child_path))
    return problems

problems = missing_keys(example, overlay)
if problems:
    print("ERROR (jira plugin): user overlay is missing required keys:", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    print(f"See {example_path} for the expected shape.", file=sys.stderr)
    sys.exit(2)
' "$overlay_example" < "$overlay_file" || exit 2

# ---------------------------------------------------------------------------
# 6. Build a curl --config file with the Basic Authorization header so the
#    token never appears on any command line.
# ---------------------------------------------------------------------------
_xt_was_on=""
case "$-" in *x*) _xt_was_on=1 ;; esac
{ set +x; } 2>/dev/null

JIRA_CURL_CONFIG=$(mktemp 2>/dev/null || mktemp -t jira-curl)
chmod 600 "$JIRA_CURL_CONFIG"
auth_b64=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 | tr -d '\n')
printf 'header = "Authorization: Basic %s"\n' "$auth_b64" > "$JIRA_CURL_CONFIG"
unset auth_b64

export JIRA_OVERLAY_FILE="$overlay_file"
export JIRA_PYTHON="$PY_WITH_YAML"
export JIRA_CURL_CONFIG

[[ -n "$_xt_was_on" ]] && set -x
unset _xt_was_on
