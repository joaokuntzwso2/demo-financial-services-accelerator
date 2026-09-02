#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$ROOT/demo/lib-finlink.sh"

finlink_ensure
finlink_start_and_wait payments

echo
echo "==> EXECUTE PAYMENT"
finlink_action payments execute | jq .

echo
echo "==> PAYMENT STATUS"
finlink_action payments status | jq .

echo
echo "[OK] Payments journey passed"
