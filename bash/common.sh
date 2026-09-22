#!/usr/bin/env bash
# common.sh — shared helpers. Source this file; do not execute it directly.
# Provides: config loading, `cf` API wrapper, jq check, typed confirmation.

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$DEMO_DIR/config.sh" ]]; then
  # shellcheck disable=SC1091
  source "$DEMO_DIR/config.sh"
else
  echo "ERROR: config.sh not found." >&2
  echo "       cp config.example.sh config.sh   then fill in credentials." >&2
  exit 1
fi

API="https://api.cloudflare.com/client/v4"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required (brew install jq)" >&2; exit 1; }

# cf METHOD PATH [JSON_BODY]
# Prints the JSON body followed by a "HTTP_STATUS:<code>" line.
cf() {
  local method="$1" path="$2" body="${3:-}"
  local -a args=(-sS -X "$method" -H "Content-Type: application/json" -w "\nHTTP_STATUS:%{http_code}")
  if [[ -n "${CF_API_TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer $CF_API_TOKEN")
  elif [[ -n "${CF_AUTH_EMAIL:-}" && -n "${CF_AUTH_KEY:-}" ]]; then
    args+=(-H "X-Auth-Email: $CF_AUTH_EMAIL" -H "X-Auth-Key: $CF_AUTH_KEY")
  else
    echo "ERROR: set CF_API_TOKEN or CF_AUTH_EMAIL + CF_AUTH_KEY in config.sh" >&2
    exit 1
  fi
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}" "$API$path"
}

# cf_json METHOD PATH [JSON_BODY] — same as cf but returns only the JSON body.
cf_json() {
  cf "$@" | sed 's/^HTTP_STATUS:.*$//' | jq .
}

# One-call status+body pattern for callers (no second API call):
#   RESP=$(cf METHOD PATH)
#   STATUS=$(printf '%s' "$RESP" | tail -n1 | cut -d: -f2)
#   BODY=$(printf '%s' "$RESP" | sed 's/^HTTP_STATUS:.*$//')

# CF_ALL_STATUS — HTTP status of the last cf_all_to page (global; survives return 1).
CF_ALL_STATUS=0

# cf_all_to OUTVAR METHOD PATH — fetch ALL pages (50/page) of a list endpoint.
# Assigns the merged JSON ({result, result_info}) to OUTVAR and sets CF_ALL_STATUS
# IN THE CURRENT SHELL (printf -v — no command substitution, so globals survive).
# PATH must not embed page/per_page (this helper owns paging).
# On failure: OUTVAR untouched, error to stderr, returns 1 with CF_ALL_STATUS set.
# Strict call sites abort via set -e; tolerant ones branch on CF_ALL_STATUS.
# NEVER capture cf_all_to in $( ) — a subshell would discard CF_ALL_STATUS.
cf_all_to() {
  local outvar="$1" method="$2" path="$3" sep page=1 pages body bodies resp merged
  CF_ALL_STATUS=0
  if [[ "$path" == *"?"* ]]; then sep="&"; else sep="?"; fi
  bodies=""
  while :; do
    resp=$(cf "$method" "$path${sep}page=$page&per_page=50") || {
      echo "ERROR: $path page $page: curl transport failure" >&2
      return 1
    }
    CF_ALL_STATUS=$(printf '%s' "$resp" | tail -n1 | cut -d: -f2)
    if [[ "$CF_ALL_STATUS" != "200" ]]; then
      echo "ERROR: $path page $page returned HTTP $CF_ALL_STATUS" >&2
      return 1
    fi
    body=$(printf '%s' "$resp" | sed 's/^HTTP_STATUS:.*$//')
    bodies="$bodies$body"$'\n'
    pages=$(printf '%s' "$body" | jq -r '.result_info.total_pages // 1') || pages=1
    [[ "$pages" =~ ^[0-9]+$ ]] || pages=1
    if [[ "$page" -ge "$pages" ]]; then break; fi
    page=$((page + 1))
  done
  merged=$(printf '%s' "$bodies" | jq -s '{result: (map(.result // []) | add // []), result_info: (.[-1].result_info)}') || {
    echo "ERROR: $path: failed to merge pages" >&2
    return 1
  }
  printf -v "$outvar" '%s' "$merged"
}

# confirm_or_abort PROMPT EXPECTED_TEXT
# Requires the operator to type EXPECTED_TEXT exactly, from an interactive TTY.
# Reads /dev/tty so piped/redirected stdin can never satisfy the gate.
confirm_or_abort() {
  local prompt="$1" expected="$2" answer=""
  if ! read -r -p "$prompt" answer </dev/tty; then
    echo "Aborted: no interactive terminal available for confirmation. Nothing was done." >&2
    exit 1
  fi
  if [[ "$answer" != "$expected" ]]; then
    echo "Aborted: confirmation text did not match. Nothing was done."
    exit 1
  fi
}
