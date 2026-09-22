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
#
# Exit status: 0 if every section was readable, 1 if any section could not be
# read. An unreadable section is never reported as "none" — the whole point of
# the preflight is to distinguish "nothing there" from "cannot see".

set -euo pipefail
source "$(dirname "$0")/common.sh"

TARGET_NAME="${1:-${TARGET_ACCOUNT_NAME:?Set TARGET_ACCOUNT_NAME in config.sh or pass account name as arg 1}}"

INCOMPLETE=0
unreadable() {  # unreadable LABEL STATUS
  INCOMPLETE=$((INCOMPLETE + 1))
  echo "UNREADABLE: $1 (HTTP $2) — this credential cannot see it; do NOT read this as 'none'"
}

echo "== 1. Locate account by EXACT name: '$TARGET_NAME' =="
if ! cf_all_to ACCOUNTS GET "/accounts"; then
  echo "ERROR: could not list accounts (HTTP $CF_ALL_STATUS)." >&2
  exit 1
fi
printf '%s' "$ACCOUNTS" | jq -r '.result[] | "\(.id)  \(.name)"'

ACCOUNT_MATCHES=$(printf '%s' "$ACCOUNTS" | jq -r --arg n "$TARGET_NAME" '.result[] | select(.name == $n) | .id')
ACCOUNT_MATCH_COUNT=$(printf '%s\n' "$ACCOUNT_MATCHES" | grep -c . || true)
if [[ "$ACCOUNT_MATCH_COUNT" -eq 0 ]]; then
  echo "No account with that exact name visible to this credential."
  echo "If the name is right but invisible, the credential's user may only be a member, not the owner."
  exit 1
fi
if [[ "$ACCOUNT_MATCH_COUNT" -gt 1 ]]; then
  # Cloudflare does not enforce unique account names.
  echo "ERROR: $ACCOUNT_MATCH_COUNT accounts share the exact name '$TARGET_NAME':" >&2
  printf '%s\n' "$ACCOUNT_MATCHES" | sed 's/^/  /' >&2
  echo "Refusing to guess which one you mean. Rename the target account so its name is unique." >&2
  exit 1
fi
ACCOUNT_ID="$ACCOUNT_MATCHES"
echo "MATCHED ACCOUNT_ID: $ACCOUNT_ID"

echo
echo "== 2. Account details =="
ACCT_RESP=$(cf GET "/accounts/$ACCOUNT_ID")
ACCT_STATUS=$(cf_status "$ACCT_RESP")
if [[ "$ACCT_STATUS" == "200" ]]; then
  cf_body "$ACCT_RESP" | jq '.result | {id, name, created_on: (.created_on // "n/a")}'
else
  unreadable "account details" "$ACCT_STATUS"
fi

echo
echo "== 3. Zones under this account (these get destroyed with the account) =="
if cf_all_to ZONES GET "/zones?account.id=$ACCOUNT_ID"; then
  printf '%s' "$ZONES" | jq -r 'if ((.result // []) | length) == 0 then "none" else .result[] | "\(.id)  \(.name)  status=\(.status)" end'
else
  unreadable "zone list" "$CF_ALL_STATUS"
fi

echo
echo "== 4. Subscriptions/entitlements (cancel BEFORE deletion; active subs are the most common cause of a failed delete) =="
SUB_RESP=$(cf GET "/accounts/$ACCOUNT_ID/subscriptions")
SUB_STATUS=$(cf_status "$SUB_RESP")
if [[ "$SUB_STATUS" == "200" ]]; then
  cf_body "$SUB_RESP" | jq -r 'if ((.result // []) | length) == 0 then "none" else .result[]? | "\(.id // "?")  product=\(.product.name // .product_name // "?")  state=\(.state // "?")" end'
else
  unreadable "subscription list" "$SUB_STATUS"
fi

echo
echo "== 5. Logpush jobs (delete manually BEFORE account deletion) =="
if cf_all_to LOGPUSH GET "/accounts/$ACCOUNT_ID/logpush/jobs"; then
  printf '%s' "$LOGPUSH" | jq -r 'if ((.result // []) | length) == 0 then "none" else .result[] | "\(.id)  destination=\(.destination_conf)" end'
else
  unreadable "logpush jobs" "$CF_ALL_STATUS"
fi

echo
echo "== 6. Zero Trust gateway configuration (delete manually BEFORE account deletion) =="
GW_RESP=$(cf GET "/accounts/$ACCOUNT_ID/gateway")
GW_STATUS=$(cf_status "$GW_RESP")
if [[ "$GW_STATUS" == "200" ]]; then
  cf_body "$GW_RESP" | jq '.result | {id, name}'
elif [[ "$GW_STATUS" == "404" ]]; then
  echo "none"
else
  # 403 means "cannot see", not "not there" — reporting it as absent would hide
  # a gateway configuration that keeps resolving DNS after the account is gone.
  unreadable "gateway configuration" "$GW_STATUS"
fi

echo
echo "== 7. Access organization (delete manually BEFORE account deletion) =="
AO_RESP=$(cf GET "/accounts/$ACCOUNT_ID/access/organizations")
AO_STATUS=$(cf_status "$AO_RESP")
if [[ "$AO_STATUS" == "200" ]]; then
  cf_body "$AO_RESP" | jq '.result | {id, name}'
elif [[ "$AO_STATUS" == "404" ]]; then
  echo "none"
else
  unreadable "Access organization" "$AO_STATUS"
fi

echo
echo "== 8. Members with access to this account =="
if cf_all_to MEMBERS GET "/accounts/$ACCOUNT_ID/members"; then
  # Roles come back as objects or as plain strings depending on the auth used;
  # indexing a string with .name would abort the whole preflight under set -e.
  printf '%s' "$MEMBERS" | jq -r '
    if ((.result // []) | length) == 0
    then "none"
    else .result[]?
         | "\(.user.email)  role=\(if ((.roles // []) | length) == 0 then "?" elif (.roles[0] | type) == "object" then (.roles[0].name // "?") else .roles[0] end)  status=\(.status)"
    end'
else
  unreadable "member list" "$CF_ALL_STATUS"
fi

echo
echo "== 9. Your membership entry for this account =="
if cf_all_to MEMBERSHIPS GET "/memberships"; then
  printf '%s' "$MEMBERSHIPS" | jq -r --arg n "$TARGET_NAME" '
    if ((.result // []) | map(select(.account.name == $n)) | length) == 0
    then "no membership entry for this account name"
    else .result[] | select(.account.name == $n)
         | "membership_id=\(.id)  status=\(.status)  roles=\(.roles | map(if type == "object" then .name else . end) | join(","))"
    end'
else
  unreadable "membership list" "$CF_ALL_STATUS"
fi

echo
if [[ "$INCOMPLETE" -gt 0 ]]; then
  echo "Precheck INCOMPLETE. No changes were made, but $INCOMPLETE section(s) could not be read."
  echo "Do not treat an unreadable section as empty — fix the credential's permissions and re-run"
  echo "before deciding anything. delete-account.sh --execute will abort on the same gaps."
  exit 1
fi
echo "Precheck complete. No changes were made."
