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

assert_interactive_terminal

TARGET_NAME="${TARGET_ACCOUNT_NAME:?Set TARGET_ACCOUNT_NAME in config.sh}"

echo "== Find membership for account '$TARGET_NAME' =="
if ! cf_all_to MEMBERSHIPS GET "/memberships"; then
  echo "ERROR: could not list memberships (HTTP $CF_ALL_STATUS). Aborting." >&2
  exit 1
fi
MEMBERSHIP_IDS=$(printf '%s' "$MEMBERSHIPS" | jq -r --arg n "$TARGET_NAME" '.result[] | select(.account.name == $n) | .id')
MEMBERSHIP_COUNT=$(printf '%s\n' "$MEMBERSHIP_IDS" | grep -c . || true)
if [[ "$MEMBERSHIP_COUNT" -eq 0 ]]; then
  echo "No membership found for that name. Nothing to do."
  exit 1
fi
if [[ "$MEMBERSHIP_COUNT" -gt 1 ]]; then
  # Account names are not unique, so one name can map to several memberships.
  echo "ERROR: $MEMBERSHIP_COUNT memberships match the exact name '$TARGET_NAME':" >&2
  printf '%s' "$MEMBERSHIPS" | jq -r --arg n "$TARGET_NAME" '.result[] | select(.account.name == $n) | "  membership_id=\(.id)  account_id=\(.account.id)"' >&2
  echo "Refusing to guess which one to leave." >&2
  exit 1
fi
MEMBERSHIP_ID="$MEMBERSHIP_IDS"

echo "membership_id: $MEMBERSHIP_ID"
printf '%s' "$MEMBERSHIPS" | jq -r --arg n "$TARGET_NAME" '.result[] | select(.account.name == $n) | "account=\(.account.name)  id=\(.account.id)  status=\(.status)  roles=\(.roles | map(if type == "object" then .name else . end) | join(","))"'

echo
echo "Removing this membership hides the account from this user's dashboard."
echo "The account itself is NOT deleted."
confirm_or_abort "Type 'LEAVE' to confirm: " "LEAVE"

RESP=$(cf DELETE "/memberships/$MEMBERSHIP_ID")
STATUS=$(cf_status "$RESP")
cf_body "$RESP" | jq '{success, errors}' 2>/dev/null || true
cf_summary "$RESP" "$STATUS"
if [[ "$STATUS" != "200" ]]; then
  echo "ERROR: membership DELETE returned HTTP $STATUS — nothing was removed." >&2
  exit 1
fi

echo
echo "== Verification: membership should be gone =="
if ! cf_all_to VERIFY GET "/memberships"; then
  echo "ERROR: could not re-read memberships (HTTP $CF_ALL_STATUS) — deletion unverified." >&2
  exit 1
fi
STILL_PRESENT=$(printf '%s' "$VERIFY" | jq -r --arg n "$TARGET_NAME" '(.result // []) | map(select(.account.name == $n)) | length')
if [[ "$STILL_PRESENT" -eq 0 ]]; then
  echo "membership removed — account no longer listed for this user"
else
  echo "ERROR: membership still present after the delete." >&2
  exit 1
fi
