#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$ROOT/demo/lib-finlink.sh"

finlink_ensure

OUT="$(
  finlink_curl \
    -X POST \
    "$FINLINK_URL/api/negative-tests" \
    -H 'Content-Type: application/json' \
    -d '{}'
)"

jq . <<<"$OUT"
jq -e '.all_passed == true' <<<"$OUT" >/dev/null

echo
echo "[OK] Negative security tests passed"
