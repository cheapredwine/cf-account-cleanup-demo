#!/usr/bin/env bash
# delete-account.sh — PERMANENT account deletion via the Tenant API.
#
# Usage:
#   ./delete-account.sh                dry run (no changes, shows the plan)
#   ./delete-account.sh --execute      perform prerequisite cleanup + deletion
#                                      (still requires typing the account ID)
#
# IMPORTANT CONSTRAINTS (see https://developers.cloudflare.com/tenant/how-to/manage-accounts/)
#   * DELETE /accounts/{account_id} is "only available for tenant admins at this time"
#     — it works for accounts owned/created by the tenant behind this credential.
#     A normal customer account typically CANNOT self-delete via API; that is done
#     by the Cloudflare account team/support.
#   * Deletion is PERMANENT and destroys zones and most resources under the account.
#   * NOT auto-deleted: Logpush jobs, Zero Trust gateway configuration, Access
#     organization. This script removes those first in --execute mode.
#   * Subscriptions: the Tenant docs do not list them as a manual pre-delete,
#     but in practice leftover paid subscriptions are the most common cause of a
#     failed delete. Phase 0 aborts if any are visible; cancel via billing first.
#   * Cleanup phases (1-3) must return 200/404 or the run aborts BEFORE the
#     irreversible account delete.
#   * Order of operations (docs): gateway config -> access organization -> account.

set -euo pipefail
source "$(dirname "$0")/common.sh"

EXECUTE=false
[[ "${1:-}" == "--execute" ]] && EXECUTE=true

TARGET_NAME="${TARGET_ACCOUNT_NAME:?Set TARGET_ACCOUNT_NAME in config.sh}"

# Phase-assert helper: every pre-delete mutation must return 200/404.
assert_cleanup_status() {
  local label="$1" resp="$2" status="$3"
  if [[ "$status" != "200" && "$status" != "404" ]]; then
    echo "ERROR: $label returned HTTP $status — aborting before account deletion." >&2
    printf '%s' "$resp" | sed 's/^HTTP_STATUS:.*$//' | jq '{success, errors}' 2>/dev/null || true
    exit 1
  fi
}

# Fresh paginated logpush inventory (used by dry-run display and --execute).
harvest_logpush_ids() {
  local resp=""
  cf_all_to resp GET "/accounts/$ACCOUNT_ID/logpush/jobs" 2>/dev/null || true
  printf '%s' "$resp" | jq -r '.result[]?.id' 2>/dev/null || true
}

echo "== Locate account by EXACT name: '$TARGET_NAME' =="
cf_all_to ACCOUNTS GET "/accounts"
ACCOUNT_ID=$(printf '%s' "$ACCOUNTS" | jq -r --arg n "$TARGET_NAME" '.result[] | select(.name == $n) | .id' | head -n1)
[[ -n "$ACCOUNT_ID" ]] || { echo "ERROR: no account with that exact name. Aborting."; exit 1; }
echo "ACCOUNT_ID: $ACCOUNT_ID"

echo
echo "== Pre-deletion inventory =="
cf_all_to ZONES_RESP GET "/zones?account.id=$ACCOUNT_ID"
ZONES=$(printf '%s' "$ZONES_RESP" | jq -r '[.result[]?.name] | join(",")')
LOGPUSH_IDS=$(harvest_logpush_ids)
cf_all_to MEMBERS GET "/accounts/$ACCOUNT_ID/members" 2>/dev/null || true
MEMBER_COUNT='?'
if [[ "$CF_ALL_STATUS" == "200" ]]; then
  MEMBER_COUNT=$(printf '%s' "$MEMBERS" | jq '(.result // []) | length')
fi
echo "  zones that will be destroyed : ${ZONES:-none}"
echo "  logpush jobs to remove       : ${LOGPUSH_IDS:-(none found)}"
echo "  member count                 : $MEMBER_COUNT"

if ! $EXECUTE; then
  echo
  echo "DRY RUN — nothing was changed."
  echo "Plan if run with --execute:"
  echo "  0. subscriptions: abort if any active subscriptions exist (cancel them"
  echo "     via billing first — leftover subs are the most common cause of a failed delete)"
  echo "  1. DELETE logpush jobs: ${LOGPUSH_IDS:-(none)}"
  echo "  2. DELETE /accounts/$ACCOUNT_ID/gateway            (Zero Trust gateway config)"
  echo "  3. DELETE /accounts/$ACCOUNT_ID/access/organizations"
  echo "  4. DELETE /accounts/$ACCOUNT_ID                    (permanent)"
  exit 0
fi

echo
echo "== Phase 0: subscription check (abort if active subscriptions exist) =="
# The Tenant docs require Logpush/gateway/Access cleanup before deletion; paid
# subscriptions are not listed there, but in practice a leftover subscription is
# the most common cause of a failed delete. Cancel those via billing first.
SUB_RESP=$(cf GET "/accounts/$ACCOUNT_ID/subscriptions")
SUB_STATUS=$(printf '%s' "$SUB_RESP" | tail -n1 | cut -d: -f2)
if [[ "$SUB_STATUS" == "200" ]]; then
  SUB_COUNT=$(printf '%s' "$SUB_RESP" | sed 's/^HTTP_STATUS:.*$//' | jq '(.result // [] | length)')
  if [[ "$SUB_COUNT" -gt 0 ]]; then
    echo "ERROR: $SUB_COUNT active subscription(s) found. Cancel them via billing first, then re-run."
    printf '%s' "$SUB_RESP" | sed 's/^HTTP_STATUS:.*$//' | jq -r '.result[]? | "  sub \(.id // "?")  product=\(.product.name // .product_name // "?")  state=\(.state // "?")"'
    exit 1
  fi
  echo "  no active subscriptions"
else
  echo "  subscription list not visible to this credential (HTTP $SUB_STATUS) — verify billing manually before proceeding"
fi

echo
echo "== Phase 1: remove logpush jobs (fresh inventory) =="
LOGPUSH_IDS=$(harvest_logpush_ids)
while IFS= read -r job_id; do
  [[ -z "$job_id" ]] && continue
  echo "  deleting logpush job $job_id"
  RESP=$(cf DELETE "/accounts/$ACCOUNT_ID/logpush/jobs/$job_id")
  STATUS=$(printf '%s' "$RESP" | tail -n1 | cut -d: -f2)
  assert_cleanup_status "logpush job $job_id DELETE" "$RESP" "$STATUS"
  echo "    HTTP $STATUS"
done <<< "$LOGPUSH_IDS"

echo
echo "== Phase 2: remove Zero Trust gateway configuration =="
RESP=$(cf DELETE "/accounts/$ACCOUNT_ID/gateway")
STATUS=$(printf '%s' "$RESP" | tail -n1 | cut -d: -f2)
assert_cleanup_status "gateway DELETE" "$RESP" "$STATUS"
echo "  gateway DELETE: HTTP $STATUS"

echo
echo "== Phase 3: remove Access organization =="
RESP=$(cf DELETE "/accounts/$ACCOUNT_ID/access/organizations")
STATUS=$(printf '%s' "$RESP" | tail -n1 | cut -d: -f2)
assert_cleanup_status "Access organization DELETE" "$RESP" "$STATUS"
echo "  Access organization DELETE: HTTP $STATUS"

echo
echo "== Phase 4: delete the account =="
echo "This is PERMANENT. Zones: ${ZONES:-none} will be destroyed and cannot be recovered."
confirm_or_abort "Type the full 32-character account ID to confirm: " "$ACCOUNT_ID"
cf_json DELETE "/accounts/$ACCOUNT_ID" | jq '{success, result, errors}'

echo
echo "== Verification: account should now be gone =="
STATUS=$(cf GET "/accounts/$ACCOUNT_ID" | tail -n1 | cut -d: -f2)
echo "GET /accounts/$ACCOUNT_ID returned HTTP $STATUS (expect 403/404)"
