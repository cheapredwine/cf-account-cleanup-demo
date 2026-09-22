#!/usr/bin/env bash
# precheck.sh — READ-ONLY preflight before deleting an account.
# Performs zero mutations. Run this first and share the output before any delete.
#
# What it inspects, per https://developers.cloudflare.com/tenant/how-to/manage-accounts/
#   1. Locate the account by exact name match -> account ID
#   2. Account details (id, name, created date)
#   3. Zones under the account (destroyed by account deletion)
#   4. Subscriptions/entitlements — cancel before deletion; active subs are
#      the most common cause of a failed delete (billing-linked)
#   5. Logpush jobs          — NOT auto-deleted; must be removed manually first
#   6. Zero Trust gateway configuration — NOT auto-deleted; remove manually
#   7. Access organization   — NOT auto-deleted; remove manually
#   8. Members with access   — confirm nobody else relies on this account
#   9. Your membership view  — how this account is attached to your user

set -euo pipefail
source "$(dirname "$0")/common.sh"

TARGET_NAME="${1:-${TARGET_ACCOUNT_NAME:?Set TARGET_ACCOUNT_NAME in config.sh or pass account name as arg 1}}"

echo "== 1. Locate account by EXACT name: '$TARGET_NAME' =="
cf_all_to ACCOUNTS GET "/accounts"
printf '%s' "$ACCOUNTS" | jq -r '.result[] | "\(.id)  \(.name)"'

ACCOUNT_ID=$(printf '%s' "$ACCOUNTS" | jq -r --arg n "$TARGET_NAME" '.result[] | select(.name == $n) | .id' | head -n1)
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
cf_all_to ZONES GET "/zones?account.id=$ACCOUNT_ID"
printf '%s' "$ZONES" | jq -r 'if ((.result // []) | length) == 0 then "none" else .result[] | "\(.id)  \(.name)  status=\(.status)" end'

echo
echo "== 4. Subscriptions/entitlements (cancel BEFORE deletion; active subs are the most common cause of a failed delete) =="
SUB_RESP=$(cf GET "/accounts/$ACCOUNT_ID/subscriptions")
SUB_STATUS=$(printf '%s' "$SUB_RESP" | tail -n1 | cut -d: -f2)
if [[ "$SUB_STATUS" == "200" ]]; then
  printf '%s' "$SUB_RESP" | sed 's/^HTTP_STATUS:.*$//' | jq -r 'if ((.result // []) | length) == 0 then "none" else .result[]? | "\(.id // "?")  product=\(.product.name // .product_name // "?")  state=\(.state // "?")" end' 2>/dev/null
else
  echo "subscriptions list not visible to this credential (HTTP $SUB_STATUS) — verify billing manually before deleting"
fi

echo
echo "== 5. Logpush jobs (delete manually BEFORE account deletion) =="
cf_all_to LOGPUSH GET "/accounts/$ACCOUNT_ID/logpush/jobs" 2>/dev/null || true
if [[ "$CF_ALL_STATUS" == "200" ]]; then
  printf '%s' "$LOGPUSH" | jq -r 'if ((.result // []) | length) == 0 then "none" else .result[] | "\(.id)  destination=\(.destination_conf)" end'
else
  echo "endpoint not available for this credential (HTTP $CF_ALL_STATUS)"
fi

echo
echo "== 6. Zero Trust gateway configuration (delete manually BEFORE account deletion) =="
GW_RESP=$(cf GET "/accounts/$ACCOUNT_ID/gateway")
GW_STATUS=$(printf '%s' "$GW_RESP" | tail -n1 | cut -d: -f2)
if [[ "$GW_STATUS" == "200" ]]; then
  printf '%s' "$GW_RESP" | sed 's/^HTTP_STATUS:.*$//' | jq '.result | {id, name}'
else
  echo "no gateway configuration (HTTP $GW_STATUS)"
fi

echo
echo "== 7. Access organization (delete manually BEFORE account deletion) =="
AO_RESP=$(cf GET "/accounts/$ACCOUNT_ID/access/organizations")
AO_STATUS=$(printf '%s' "$AO_RESP" | tail -n1 | cut -d: -f2)
if [[ "$AO_STATUS" == "200" ]]; then
  printf '%s' "$AO_RESP" | sed 's/^HTTP_STATUS:.*$//' | jq '.result | {id, name}'
else
  echo "no access organization (HTTP $AO_STATUS)"
fi

echo
echo "== 8. Members with access to this account =="
cf_all_to MEMBERS GET "/accounts/$ACCOUNT_ID/members" 2>/dev/null || true
if [[ "$CF_ALL_STATUS" == "200" ]]; then
  printf '%s' "$MEMBERS" | jq -r '.result[]? | "\(.user.email)  role=\(.roles[0].name // "?")  status=\(.status)"'
else
  echo "members list not available for this credential (HTTP $CF_ALL_STATUS)"
fi

echo
echo "== 9. Your membership entry for this account =="
cf_all_to MEMBERSHIPS GET "/memberships"
printf '%s' "$MEMBERSHIPS" | jq -r --arg n "$TARGET_NAME" '.result[] | select(.account.name == $n) | "membership_id=\(.id)  status=\(.status)  roles=\(.roles | map(if type == "object" then .name else . end) | join(","))"'

echo
echo "Precheck complete. No changes were made."
