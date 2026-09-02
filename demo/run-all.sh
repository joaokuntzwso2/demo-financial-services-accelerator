#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

"$ROOT/demo/accounts.sh"
"$ROOT/demo/payments.sh"
"$ROOT/demo/funds.sh"
"$ROOT/demo/negative-tests.sh"

echo
echo "[OK] FINLINK END-TO-END DEMO PASSED"
