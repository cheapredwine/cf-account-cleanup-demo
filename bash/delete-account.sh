#!/usr/bin/env bash
# delete-account.sh — PERMANENT account deletion via the Tenant API.
#
# Usage:
#   ./delete-account.sh                dry run (no changes, shows the plan)
#   ./delete-account.sh --execute      typed confirmation, then cleanup + deletion
#
# IMPORTANT CONSTRAINTS (see https://developers.cloudflare.com/tenant/how-to/manage-accounts/)
#   * DELETE /accounts/{account_id} is "only available for tenant admins at this time"
#     — it works for accounts owned/created by the tenant behind this credential.
#     A normal customer account typically CANNOT self-delete via API; that is done
#     by the Cloudflare account team/support.
#   * Deletion is PERMANENT and destroys zones and most resources under the account.
#   * NOT auto-deleted: Logpush jobs (keep delivering logs afterwards) and Zero Trust
#     gateway configuration (may keep resolving DNS afterwards). The docs' cleanup
#     sequence also removes the Access organization. This script does all three.
#   * Subscriptions: the Tenant docs do not list them as a manual pre-delete,
#     but in practice leftover paid subscriptions are the most common cause of a
#     failed delete. Phase 0 aborts if any are visible; cancel via billing first.
#   * An unreadable Logpush or member inventory aborts BEFORE the typed account-ID
#     confirmation. The confirmation happens before any change because cleanup
#     destroys Gateway policies and the Access organization.
#   * Cleanup phases (1-3) must return 200/404 AND not report success=false, or
#     the run aborts BEFORE the irreversible account delete. Each phase is then
#     verified by a follow-up read before the account is deleted.
#   * Order of operations (docs): gateway config -> access organization -> account.

set -euo pipefail
source "$(dirname "$0")/common.sh"

usage() {
  echo "Usage: $(basename "$0") [--execute]"
  echo "  (no args)   dry run: print the inventory and the plan, change nothing"
  echo "  --execute   typed confirmation, then prerequisite cleanup + permanent deletion"
}

EXECUTE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) EXECUTE=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

TARGET_NAME="${TARGET_ACCOUNT_NAME:?Set TARGET_ACCOUNT_NAME in config.sh}"

# assert_cleanup_ok LABEL RESP STATUS
# Every pre-delete mutation must return 200/404. A 404 means "already gone" and
# legitimately carries success=false, so the body is only judged on a 200 —
# where success=false would otherwise sail past an HTTP-status-only check.
assert_cleanup_ok() {
  local label="$1" resp="$2" status="$3" success
  if [[ "$status" != "200" && "$status" != "404" ]]; then
    echo "ERROR: $label returned HTTP $status — aborting before the account delete." >&2
    cf_body "$resp" | jq '{success, errors}' 2>/dev/null || true
    exit 1
  fi
  success=$(cf_body "$resp" | jq -r '.success // empty' 2>/dev/null || true)
  if [[ "$status" == "200" && "$success" == "false" ]]; then
    echo "ERROR: $label returned HTTP 200 with success=false — aborting before the account delete." >&2
    cf_body "$resp" | jq '{success, errors}' 2>/dev/null || true
    exit 1
  fi
}

# refresh_logpush_ids — set LOGPUSH_IDS (newline-separated) and LOGPUSH_READABLE.
# Sets globals in the current shell; never call this in $( ), which would lose
# both the readable flag and CF_ALL_STATUS.
#
# An unreadable inventory is NOT the same as an empty one. Logpush jobs left
# behind keep delivering logs after the account is gone, so a 403 here must stop
# the run rather than quietly skip Phase 1.
refresh_logpush_ids() {
  LOGPUSH_IDS=""
  LOGPUSH_READABLE=false
  if cf_all_to LOGPUSH_JSON GET "/accounts/$ACCOUNT_ID/logpush/jobs"; then
    LOGPUSH_READABLE=true
    LOGPUSH_IDS=$(printf '%s' "$LOGPUSH_JSON" | jq -r '.result[]?.id')
  fi
  # Snapshot the status: CF_ALL_STATUS belongs to the most recent cf_all_to call
  # anywhere, so a later listing would overwrite it before we report on logpush.
  LOGPUSH_STATUS="$CF_ALL_STATUS"
}

# verify_absent LABEL PATH — accept an absent endpoint as 404 or 200 with no ID.
verify_absent() {
  local label="$1" path="$2" resp status id
  resp=$(cf GET "$path")
  status=$(cf_status "$resp")
  if [[ "$status" == "404" ]]; then
    echo "  verified: $label is gone"
    return
  fi
  if [[ "$status" == "200" ]]; then
    id=$(cf_body "$resp" | jq -r '.result.id // empty' 2>/dev/null || true)
    if [[ -z "$id" ]]; then
      echo "  verified: $label is gone"
      return
    fi
    echo "ERROR: $label is still present after its DELETE — aborting before the account delete." >&2
    exit 1
  fi
  echo "ERROR: could not verify $label is gone (GET $path returned HTTP $status)." >&2
  echo "       Grant read access to this path and re-run; aborting before the account delete." >&2
  exit 1
}

echo "== Locate account by EXACT name: '$TARGET_NAME' =="
if ! cf_all_to ACCOUNTS GET "/accounts"; then
  echo "ERROR: could not list accounts (HTTP $CF_ALL_STATUS). Aborting." >&2
  exit 1
fi
ACCOUNT_MATCHES=$(printf '%s' "$ACCOUNTS" | jq -r --arg n "$TARGET_NAME" '.result[] | select(.name == $n) | .id')
ACCOUNT_MATCH_COUNT=$(printf '%s\n' "$ACCOUNT_MATCHES" | grep -c . || true)
if [[ "$ACCOUNT_MATCH_COUNT" -eq 0 ]]; then
  echo "ERROR: no account with that exact name. Aborting." >&2
  exit 1
fi
if [[ "$ACCOUNT_MATCH_COUNT" -gt 1 ]]; then
  # Cloudflare does not enforce unique account names. Picking the first match
  # would be a coin flip over which account gets destroyed.
  echo "ERROR: $ACCOUNT_MATCH_COUNT accounts share the exact name '$TARGET_NAME':" >&2
  printf '%s\n' "$ACCOUNT_MATCHES" | sed 's/^/  /' >&2
  echo "Refusing to guess. Rename the target account so its name is unique, then re-run." >&2
  exit 1
fi
ACCOUNT_ID="$ACCOUNT_MATCHES"
echo "ACCOUNT_ID: $ACCOUNT_ID"

echo
echo "== Pre-deletion inventory =="
if ! cf_all_to ZONES_RESP GET "/zones?account.id=$ACCOUNT_ID"; then
  echo "ERROR: could not list zones (HTTP $CF_ALL_STATUS) — refusing to delete an account" >&2
  echo "       whose contents cannot be shown. Aborting." >&2
  exit 1
fi
ZONES=$(printf '%s' "$ZONES_RESP" | jq -r '[.result[]?.name] | join(",")')
refresh_logpush_ids
cf_all_to MEMBERS GET "/accounts/$ACCOUNT_ID/members" 2>/dev/null || true
MEMBER_COUNT='?'
MEMBERS_READABLE=false
MEMBERS_STATUS="$CF_ALL_STATUS"
if [[ "$CF_ALL_STATUS" == "200" ]]; then
  MEMBERS_READABLE=true
  MEMBER_COUNT=$(printf '%s' "$MEMBERS" | jq '(.result // []) | length')
fi
echo "  zones that will be destroyed : ${ZONES:-none}"
if $LOGPUSH_READABLE; then
  echo "  logpush jobs to remove       : ${LOGPUSH_IDS:-(none found)}"
else
  echo "  logpush jobs to remove       : UNREADABLE (HTTP $LOGPUSH_STATUS) — not the same as none"
fi
if $MEMBERS_READABLE; then
  echo "  member count                 : $MEMBER_COUNT"
else
  echo "  member count                 : UNREADABLE (HTTP $MEMBERS_STATUS) — not the same as zero"
fi

INVENTORY_GAPS=0
INVENTORY_GAP_DETAILS=""
if ! $LOGPUSH_READABLE; then
  INVENTORY_GAPS=$((INVENTORY_GAPS + 1))
  INVENTORY_GAP_DETAILS+="logpush jobs (HTTP $LOGPUSH_STATUS)"$'\n'
fi
if ! $MEMBERS_READABLE; then
  INVENTORY_GAPS=$((INVENTORY_GAPS + 1))
  INVENTORY_GAP_DETAILS+="account members (HTTP $MEMBERS_STATUS)"$'\n'
fi

if ! $EXECUTE; then
  echo
  echo "DRY RUN - nothing was changed."
  echo "Plan if executed:"
  echo "  gate 1. require complete logpush and member inventories before confirmation"
  echo "  gate 2. type the full account ID to confirm - asked BEFORE any change is made"
  echo "  0. subscriptions: abort if any active subscriptions exist (cancel them"
  echo "     via billing first - list every page before deciding)"
  echo "  1. DELETE logpush jobs: ${LOGPUSH_IDS:-(none)}; then re-list them and require that none remain"
  echo "  2. DELETE /accounts/$ACCOUNT_ID/gateway            (Zero Trust gateway config); then read it back and require it to be gone"
  echo "  3. DELETE /accounts/$ACCOUNT_ID/access/organizations; then read it back and require it to be gone"
  echo "  4. DELETE /accounts/$ACCOUNT_ID                    (permanent)"
  if [[ "$INVENTORY_GAPS" -gt 0 ]]; then
    echo
    echo "NOTE: unreadable inventory:"
    printf '%s' "$INVENTORY_GAP_DETAILS" | sed 's/^/      /'
    echo "      An execute run would abort before the confirmation prompt."
  fi
  exit 0
fi

if [[ "$INVENTORY_GAPS" -gt 0 ]]; then
  echo "ERROR: pre-deletion inventory incomplete — aborting before the confirmation prompt." >&2
  while IFS= read -r inventory; do
    [[ -z "$inventory" ]] && continue
    echo "       UNREADABLE: $inventory" >&2
  done <<< "$INVENTORY_GAP_DETAILS"
  exit 1
fi

echo
echo "== Confirmation (nothing has changed yet) =="
echo "This run will, in order: remove every logpush job, the Zero Trust gateway"
echo "configuration and the Access organization, then PERMANENTLY delete the account."
echo "Zones: ${ZONES:-none} will be destroyed and cannot be recovered."
echo "The cleanup steps also destroy Gateway policies and all Access apps/policies."
confirm_or_abort "Type the full 32-character account ID to confirm: " "$ACCOUNT_ID"

echo
echo "== Phase 0: subscription check (abort if active subscriptions exist) =="
# The Tenant docs require Logpush/gateway/Access cleanup before deletion; paid
# subscriptions are not listed there, but in practice a leftover subscription is
# the most common cause of a failed delete. Cancel those via billing first.
if cf_all_to SUBSCRIPTIONS GET "/accounts/$ACCOUNT_ID/subscriptions"; then
  SUB_COUNT=$(printf '%s' "$SUBSCRIPTIONS" | jq '(.result // [] | length)')
  if [[ "$SUB_COUNT" -gt 0 ]]; then
    echo "ERROR: $SUB_COUNT active subscription(s) found. Cancel them via billing first, then re-run." >&2
    printf '%s' "$SUBSCRIPTIONS" | jq -r '.result[]? | "  sub \(.id // "?")  product=\(.product.name // .product_name // "?")  state=\(.state // "?")"'
    exit 1
  fi
  echo "  no active subscriptions"
else
  # An unreadable subscription list is not a pass. Require the operator to say
  # explicitly that billing was checked out of band.
  echo "ERROR: subscription list not visible to this credential (HTTP $CF_ALL_STATUS)." >&2
  echo "       This gate cannot confirm the account is unbilled." >&2
  echo "       Check billing in the dashboard, then re-run with BILLING_VERIFIED=1 to proceed." >&2
  if [[ "${BILLING_VERIFIED:-}" != "1" ]]; then
    exit 1
  fi
  echo "  BILLING_VERIFIED=1 set by the operator — continuing without the subscription check"
fi

echo
echo "== Phase 1: remove logpush jobs (fresh inventory) =="
refresh_logpush_ids
if ! $LOGPUSH_READABLE; then
  echo "ERROR: could not list logpush jobs (HTTP $LOGPUSH_STATUS) — aborting before the account delete." >&2
  echo "       Logpush jobs left behind keep delivering logs after the account is gone," >&2
  echo "       so an unreadable inventory must not be treated as an empty one." >&2
  echo "       Grant Logpush:Read + Logpush:Edit to this credential and re-run." >&2
  exit 1
fi
if [[ -z "$LOGPUSH_IDS" ]]; then
  echo "  none"
fi
while IFS= read -r job_id; do
  [[ -z "$job_id" ]] && continue
  echo "  deleting logpush job $job_id"
  RESP=$(cf DELETE "/accounts/$ACCOUNT_ID/logpush/jobs/$job_id")
  STATUS=$(cf_status "$RESP")
  echo "    $(cf_summary "$RESP" "$STATUS")"
  assert_cleanup_ok "logpush job $job_id DELETE" "$RESP" "$STATUS"
done <<< "$LOGPUSH_IDS"
refresh_logpush_ids
if ! $LOGPUSH_READABLE; then
  echo "ERROR: could not verify logpush cleanup (HTTP $LOGPUSH_STATUS) — aborting before the account delete." >&2
  exit 1
fi
if [[ -n "$LOGPUSH_IDS" ]]; then
  echo "ERROR: logpush jobs remain after cleanup — aborting before the account delete:" >&2
  printf '%s\n' "$LOGPUSH_IDS" | sed 's/^/  /' >&2
  exit 1
fi
echo "  verified: no logpush jobs remain"

echo
echo "== Phase 2: remove Zero Trust gateway configuration =="
RESP=$(cf DELETE "/accounts/$ACCOUNT_ID/gateway")
STATUS=$(cf_status "$RESP")
echo "  gateway DELETE: $(cf_summary "$RESP" "$STATUS")"
assert_cleanup_ok "gateway DELETE" "$RESP" "$STATUS"
verify_absent "gateway configuration" "/accounts/$ACCOUNT_ID/gateway"

echo
echo "== Phase 3: remove Access organization =="
RESP=$(cf DELETE "/accounts/$ACCOUNT_ID/access/organizations")
STATUS=$(cf_status "$RESP")
echo "  Access organization DELETE: $(cf_summary "$RESP" "$STATUS")"
assert_cleanup_ok "Access organization DELETE" "$RESP" "$STATUS"
verify_absent "Access organization" "/accounts/$ACCOUNT_ID/access/organizations"

echo
echo "== Phase 4: delete the account (point of no return) =="
DEL_RESP=$(cf DELETE "/accounts/$ACCOUNT_ID")
DEL_STATUS=$(cf_status "$DEL_RESP")
cf_body "$DEL_RESP" | jq '{success, result, errors}' 2>/dev/null || true
echo "  account DELETE: $(cf_summary "$DEL_RESP" "$DEL_STATUS")"
if [[ "$DEL_STATUS" != "200" ]]; then
  echo "ERROR: account DELETE returned HTTP $DEL_STATUS — the account was NOT deleted." >&2
  echo "       Prerequisite cleanup has already run; review the account before retrying." >&2
  exit 1
fi

echo
echo "== Verification: account should now be gone =="
VERIFY_STATUS=$(cf_status "$(cf GET "/accounts/$ACCOUNT_ID")")
echo "GET /accounts/$ACCOUNT_ID returned HTTP $VERIFY_STATUS (expect 403/404)"
if [[ "$VERIFY_STATUS" != "403" && "$VERIFY_STATUS" != "404" ]]; then
  echo "ERROR: the account is still readable — deletion did not take effect." >&2
  exit 1
fi
echo "Account deleted."
