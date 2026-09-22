#!/usr/bin/env bash
# precheck.sh — READ-ONLY preflight before deleting an account.
# Performs zero mutations. Run this first and share the output before any delete.
#
# What it inspects, per https://developers.cloudflare.com/tenant/how-to/manage-accounts/
#   1. The account itself (id, name, created date)
#   2. Zones under the account (destroyed by account deletion)
#   3. Logpush jobs          — NOT auto-deleted; must be removed manually first
#   4. Zero Trust gateway configuration — NOT auto-deleted; remove manually
#   5. Access organization   — NOT auto-deleted; remove manually
#   6. Members with access   — confirm nobody else relies on this account
#   7. Your membership view  — how this account is attached to your user

set -euo pipefail
source "$(dirname "$0")/common.sh"

TARGET_NAME="${1:-${TARGET_ACCOUNT_NAME:?Set TARGET_ACCOUNT_NAME in config.sh or pass account name as arg 1}}"

echo "== 1. Locate account by EXACT name: '$TARGET_NAME' =="
ACCOUNTS=$(cf_json GET "/accounts?per_page=50")
echo "$ACCOUNTS" | jq -r '.result[] | "\(.id)  \(.name)"'

ACCOUNT_ID=$(echo "$ACCOUNTS" | jq -r --arg n "$TARGET_NAME" '.result[] | select(.name == $n) | .id' | head -n1)
if [[ -z "$ACCOUNT_ID" ]]; then
  echo "No account with that exact name visible to this credential."
  echo "If the name is right but invisible, the credential's user may only be a member, not the owner."
  exit 1
fi
echo "MATCHED ACCOUNT_ID: $ACCOUNT_ID"

echo
echo "== 2. Account details =="
cf_json GET "/accounts/$ACCOUNT_ID" | jq '.result | {id, name, created_on: (.created_on // "n/a")}'

echo
echo "== 3. Zones under this account (these get destroyed with the account) =="
cf_json GET "/zones?account.id=$ACCOUNT_ID&per_page=50" | jq -r 'if (.result | length) == 0 then "none" else .result[] | "\(.id)  \(.name)  status=\(.status)" end'

echo
echo "== 4. Logpush jobs (delete manually BEFORE account deletion) =="
cf_json GET "/accounts/$ACCOUNT_ID/logpush/jobs" | jq -r 'if (.result | length) == 0 then "none" else .result[] | "\(.id)  destination=\(.destination_conf)" end' 2>/dev/null || echo "endpoint not available for this credential"

echo
echo "== 5. Zero Trust gateway configuration (delete manually BEFORE account deletion) =="
STATUS=$(cf GET "/accounts/$ACCOUNT_ID/gateway" | tail -n1 | cut -d: -f2)
if [[ "$STATUS" == "200" ]]; then cf_json GET "/accounts/$ACCOUNT_ID/gateway" | jq '.result | {id, name}'; else echo "no gateway configuration (HTTP $STATUS)"; fi

echo
echo "== 6. Access organization (delete manually BEFORE account deletion) =="
STATUS=$(cf GET "/accounts/$ACCOUNT_ID/access/organizations" | tail -n1 | cut -d: -f2)
if [[ "$STATUS" == "200" ]]; then cf_json GET "/accounts/$ACCOUNT_ID/access/organizations" | jq '.result | {id, name}'; else echo "no access organization (HTTP $STATUS)"; fi

echo
echo "== 7. Members with access to this account =="
cf_json GET "/accounts/$ACCOUNT_ID/members?per_page=50" | jq -r '.result[]? | "\(.user.email)  role=\(.roles[0].name // "?")  status=\(.status)"' 2>/dev/null || echo "members list not available for this credential"

echo
echo "== 8. Your membership entry for this account =="
cf_json GET "/memberships?per_page=50" | jq -r --arg n "$TARGET_NAME" '.result[] | select(.account.name == $n) | "membership_id=\(.id)  status=\(.status)  roles=\(.roles | map(.name) | join(","))"'

echo
echo "Precheck complete. No changes were made."
