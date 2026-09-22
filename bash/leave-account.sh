#!/usr/bin/env bash
# leave-account.sh — OPTION A: remove the account from YOUR dashboard only.
#
# This does NOT delete the account. It removes your user's membership
# (DELETE /memberships/{membership_id}). The account, its zones, and its data
# remain intact for any other members/owner. Reversible: the owner can
# re-invite your user at any time.
#
# Use this when the goal is "stop seeing it in the dashboard".
# Use delete-account.sh only when the goal is "destroy the account entirely".

set -euo pipefail
source "$(dirname "$0")/common.sh"

TARGET_NAME="${TARGET_ACCOUNT_NAME:?Set TARGET_ACCOUNT_NAME in config.sh}"

echo "== Find membership for account '$TARGET_NAME' =="
cf_all_to MEMBERSHIPS GET "/memberships"
MEMBERSHIP_ID=$(printf '%s' "$MEMBERSHIPS" | jq -r --arg n "$TARGET_NAME" '.result[] | select(.account.name == $n) | .id' | head -n1)
[[ -n "$MEMBERSHIP_ID" ]] || { echo "No membership found for that name. Nothing to do."; exit 1; }

echo "membership_id: $MEMBERSHIP_ID"
printf '%s' "$MEMBERSHIPS" | jq -r --arg n "$TARGET_NAME" '.result[] | select(.account.name == $n) | "account=\(.account.name)  id=\(.account.id)  status=\(.status)  roles=\(.roles | map(if type == "object" then .name else . end) | join(","))"'

echo
echo "Removing this membership hides the account from this user's dashboard."
echo "The account itself is NOT deleted."
confirm_or_abort "Type 'LEAVE' to confirm: " "LEAVE"

cf_json DELETE "/memberships/$MEMBERSHIP_ID" | jq '{success, errors}'

echo
echo "== Verification: membership should be gone =="
cf_all_to VERIFY GET "/memberships"
printf '%s' "$VERIFY" | jq -r --arg n "$TARGET_NAME" 'if ((.result // []) | map(select(.account.name == $n)) | length) == 0 then "membership removed — account no longer listed for this user" else "still present" end'
