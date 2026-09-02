#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$ROOT/demo/lib-finlink.sh"

finlink_ensure
finlink_start_and_wait cof

echo
echo "==> CONFIRM FUNDS: 10.00 USD"
finlink_action cof check '{"amount":"10.00","currency":"USD"}' | jq .

echo
echo "[OK] Confirmation of Funds journey passed"
