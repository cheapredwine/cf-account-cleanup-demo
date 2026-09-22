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

# Scripts read the status separately: STATUS=$(cf ... | tail -n1 | cut -d: -f2)

# confirm_or_abort PROMPT EXPECTED_TEXT
# Requires the operator to type EXPECTED_TEXT exactly.
confirm_or_abort() {
  local prompt="$1" expected="$2" answer=""
  read -r -p "$prompt" answer
  if [[ "$answer" != "$expected" ]]; then
    echo "Aborted: confirmation text did not match. Nothing was done."
    exit 1
  fi
}
