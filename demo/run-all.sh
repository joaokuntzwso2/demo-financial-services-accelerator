#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"


echo
echo "============================================================"
echo "ACT 0 — TPP ONBOARDING"
echo "============================================================"
"$ROOT/scripts/check-fs-jwt-consent-compat.sh"
"$ROOT/demo/tpp-onboarding.sh"

"$ROOT/demo/accounts.sh"
"$ROOT/demo/payments.sh"
"$ROOT/demo/funds.sh"
"$ROOT/demo/negative-tests.sh"
"$ROOT/demo/consent-lifecycle.sh" --reuse
"$ROOT/demo/events.sh"

echo
echo "[OK] FINLINK END-TO-END DEMO PASSED"
