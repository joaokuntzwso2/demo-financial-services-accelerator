#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$ROOT/demo/lib-finlink.sh"

finlink_ensure
finlink_start_and_wait accounts

echo
echo "==> ACCOUNTS"
finlink_action accounts accounts | jq .

ACCOUNT_ID="$(
  finlink_curl "$FINLINK_URL/api/state" \
    | jq -er '.domains.accounts.account_ids[0]'
)"

echo
echo "==> BALANCES: $ACCOUNT_ID"
finlink_action accounts balances "$(jq -nc --arg id "$ACCOUNT_ID" '{account_id:$id}')" | jq .

echo
echo "==> TRANSACTIONS: $ACCOUNT_ID"
finlink_action accounts transactions "$(jq -nc --arg id "$ACCOUNT_ID" '{account_id:$id}')" | jq .

echo
echo "[OK] Accounts journey passed"
