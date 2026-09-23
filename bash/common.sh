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

# cf_auth_config — emit curl config lines carrying the credential headers.
# Credentials are handed to curl on STDIN (curl -K -), never on the command
# line: an argument list is readable by any local user via `ps` for the whole
# lifetime of the request.
cf_auth_config() {
  local v
  for v in "${CF_API_TOKEN:-}" "${CF_AUTH_EMAIL:-}" "${CF_AUTH_KEY:-}"; do
    # curl's config parser applies backslash escapes inside quoted values, so
    # refuse anything that would need escaping rather than mangling the header.
    if [[ "$v" == *[\"\\]* || "$v" == *[[:space:]]* ]]; then
      echo "ERROR: credentials must not contain whitespace, quotes or backslashes." >&2
      return 1
    fi
  done
  if [[ -n "${CF_API_TOKEN:-}" ]]; then
    printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN"
  elif [[ -n "${CF_AUTH_EMAIL:-}" && -n "${CF_AUTH_KEY:-}" ]]; then
    printf 'header = "X-Auth-Email: %s"\n' "$CF_AUTH_EMAIL"
    printf 'header = "X-Auth-Key: %s"\n'   "$CF_AUTH_KEY"
  else
    echo "ERROR: set CF_API_TOKEN or CF_AUTH_EMAIL + CF_AUTH_KEY in config.sh" >&2
    return 1
  fi
}

# cf METHOD PATH [JSON_BODY]
# Prints the JSON body followed by a "HTTP_STATUS:<code>" line.
cf() {
  local method="$1" path="$2" body="${3:-}" auth
  auth=$(cf_auth_config) || exit 1
  local -a args=(-sS --max-time 120 -X "$method"
                 -H "Content-Type: application/json"
                 -w "\nHTTP_STATUS:%{http_code}")
  [[ -n "$body" ]] && args+=(-d "$body")
  printf '%s\n' "$auth" | curl -K - "${args[@]}" "$API$path"
}

# One-call status+body pattern for callers (no second API call):
#   RESP=$(cf METHOD PATH)
#   STATUS=$(cf_status "$RESP")
#   BODY=$(cf_body "$RESP")
cf_status() { printf '%s' "$1" | tail -n1 | cut -d: -f2; }
cf_body()   { printf '%s' "$1" | sed 's/^HTTP_STATUS:.*$//'; }

# cf_summary RESP STATUS — one-line "HTTP x  success=y  errors=z" for logging.
cf_summary() {
  local body success errs
  body=$(cf_body "$1")
  success=$(printf '%s' "$body" | jq -r '.success // "n/a"' 2>/dev/null || echo "n/a")
  errs=$(printf '%s' "$body" | jq -r '[.errors[]?.message] | join("; ")' 2>/dev/null || echo "")
  echo "HTTP $2  success=$success  errors=${errs:-none}"
}

# CF_ALL_STATUS — HTTP status of the last cf_all_to page (global; survives return 1).
CF_ALL_STATUS=0

# cf_all_to OUTVAR METHOD PATH — fetch ALL pages (50/page) of a list endpoint.
# Assigns the merged JSON ({result, result_info}) to OUTVAR and sets CF_ALL_STATUS
# IN THE CURRENT SHELL (printf -v — no command substitution, so globals survive).
# PATH must not embed page/per_page (this helper owns paging).
# On failure: OUTVAR untouched, error to stderr, returns 1 with CF_ALL_STATUS set.
# Strict call sites abort via set -e; tolerant ones branch on CF_ALL_STATUS.
# NEVER capture cf_all_to in $( ) — a subshell would discard CF_ALL_STATUS.
#
# All locals below carry the _cfa_ prefix, and OUTVAR names matching it are
# rejected. Reason: bash locals are dynamically scoped, so `printf -v "$outvar"`
# resolves inside THIS function. A caller passing the name of one of our locals
# (e.g. `resp`) would have its own variable silently left untouched and would
# read an empty result — which, for the logpush inventory, means skipping a
# cleanup phase without any error. Keep the prefix and the guard together.
cf_all_to() {
  local _cfa_out="$1" _cfa_method="$2" _cfa_path="$3"
  local _cfa_sep _cfa_page=1 _cfa_pages _cfa_resp _cfa_body _cfa_bodies _cfa_merged
  CF_ALL_STATUS=0

  if [[ ! "$_cfa_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
     || [[ "$_cfa_out" == _cfa_* ]] \
     || [[ "$_cfa_out" == CF_ALL_STATUS ]]; then
    echo "ERROR: cf_all_to: unusable output variable name '$_cfa_out'" >&2
    return 1
  fi

  if [[ "$_cfa_path" == *"?"* ]]; then _cfa_sep="&"; else _cfa_sep="?"; fi
  _cfa_bodies=""
  while :; do
    _cfa_resp=$(cf "$_cfa_method" "$_cfa_path${_cfa_sep}page=$_cfa_page&per_page=50") || {
      echo "ERROR: $_cfa_path page $_cfa_page: curl transport failure" >&2
      return 1
    }
    CF_ALL_STATUS=$(cf_status "$_cfa_resp")
    if [[ "$CF_ALL_STATUS" != "200" ]]; then
      echo "ERROR: $_cfa_path page $_cfa_page returned HTTP $CF_ALL_STATUS" >&2
      return 1
    fi
    _cfa_body=$(cf_body "$_cfa_resp")
    _cfa_bodies="$_cfa_bodies$_cfa_body"$'\n'
    _cfa_pages=$(printf '%s' "$_cfa_body" | jq -r '.result_info.total_pages // 1') || _cfa_pages=1
    [[ "$_cfa_pages" =~ ^[0-9]+$ ]] || _cfa_pages=1
    if [[ "$_cfa_page" -ge "$_cfa_pages" ]]; then break; fi
    _cfa_page=$((_cfa_page + 1))
  done
  _cfa_merged=$(printf '%s' "$_cfa_bodies" | jq -s '{result: (map(.result // []) | add // []), result_info: (.[-1].result_info)}') || {
    echo "ERROR: $_cfa_path: failed to merge pages" >&2
    return 1
  }
  printf -v "$_cfa_out" '%s' "$_cfa_merged"
}

# assert_interactive_terminal — reject piped/redirected stdin before any API call.
assert_interactive_terminal() {
  if [[ ! -t 0 || ! -r /dev/tty ]]; then
    echo "Aborted: confirmation must come from an interactive terminal - piped stdin is rejected. Nothing was done." >&2
    exit 1
  fi
}

# confirm_or_abort PROMPT EXPECTED_TEXT
# Requires the operator to type EXPECTED_TEXT exactly, from an interactive TTY.
confirm_or_abort() {
  local prompt="$1" expected="$2" answer=""
  assert_interactive_terminal
  if ! read -r -p "$prompt" answer </dev/tty; then
    echo "Aborted: no interactive terminal available for confirmation. Nothing was done." >&2
    exit 1
  fi
  if [[ "$answer" != "$expected" ]]; then
    echo "Aborted: confirmation text did not match. Nothing was done."
    exit 1
  fi
}
