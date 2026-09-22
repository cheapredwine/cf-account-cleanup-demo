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
#   * Order of operations (docs): gateway config -> access organization -> account.

set -euo pipefail
source "$(dirname "$0")/common.sh"

EXECUTE=false
[[ "${1:-}" == "--execute" ]] && EXECUTE=true

TARGET_NAME="${TARGET_ACCOUNT_NAME:?Set TARGET_ACCOUNT_NAME in config.sh}"

echo "== Locate account by EXACT name: '$TARGET_NAME' =="
ACCOUNT_ID=$(cf_json GET "/accounts?per_page=50" | jq -r --arg n "$TARGET_NAME" '.result[] | select(.name == $n) | .id' | head -n1)
[[ -n "$ACCOUNT_ID" ]] || { echo "ERROR: no account with that exact name. Aborting."; exit 1; }
echo "ACCOUNT_ID: $ACCOUNT_ID"

echo
echo "== Pre-deletion inventory =="
ZONES=$(cf_json GET "/zones?account.id=$ACCOUNT_ID&per_page=50" | jq -r '.result[]?.name' | paste -sd, -)
LOGPUSH_IDS=$(cf_json GET "/accounts/$ACCOUNT_ID/logpush/jobs" | jq -r '.result[]?.id' 2>/dev/null || true)
echo "  zones that will be destroyed : ${ZONES:-none}"
echo "  logpush jobs to remove       : ${LOGPUSH_IDS:-(none found)}"
echo "  member count                 : $(cf_json GET "/accounts/$ACCOUNT_ID/members?per_page=50" | jq '.result | length' 2>/dev/null || echo '?')"

if ! $EXECUTE; then
  echo
  echo "DRY RUN — nothing was changed."
  echo "Plan if run with --execute:"
  echo "  1. DELETE logpush jobs: ${LOGPUSH_IDS:-(none)}"
  echo "  2. DELETE /accounts/$ACCOUNT_ID/gateway            (Zero Trust gateway config)"
  echo "  3. DELETE /accounts/$ACCOUNT_ID/access/organizations"
  echo "  4. DELETE /accounts/$ACCOUNT_ID                    (permanent)"
  exit 0
fi

echo
echo "== Phase 1: remove logpush jobs =="
while IFS= read -r job_id; do
  [[ -z "$job_id" ]] && continue
  echo "  deleting logpush job $job_id"
  cf_json DELETE "/accounts/$ACCOUNT_ID/logpush/jobs/$job_id" | jq '{success, errors}'
done <<< "$LOGPUSH_IDS"

echo
echo "== Phase 2: remove Zero Trust gateway configuration =="
cf_json DELETE "/accounts/$ACCOUNT_ID/gateway" | jq '{success, errors}' || true

echo
echo "== Phase 3: remove Access organization =="
cf_json DELETE "/accounts/$ACCOUNT_ID/access/organizations" | jq '{success, errors}' || true

echo
echo "== Phase 4: delete the account =="
echo "This is PERMANENT. Zones: ${ZONES:-none} will be destroyed and cannot be recovered."
confirm_or_abort "Type the full 32-character account ID to confirm: " "$ACCOUNT_ID"
cf_json DELETE "/accounts/$ACCOUNT_ID" | jq '{success, result, errors}'

echo
echo "== Verification: account should now be gone =="
STATUS=$(cf GET "/accounts/$ACCOUNT_ID" | tail -n1 | cut -d: -f2)
echo "GET /accounts/$ACCOUNT_ID returned HTTP $STATUS (expect 403/404)"
