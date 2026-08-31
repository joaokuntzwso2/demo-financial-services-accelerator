#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXPECTED=".state/certs/wso2apim.crt"
PORT="${APIM_HTTPS_PORT:-9443}"

[[ -s "$EXPECTED" ]] || {
    echo "[ERROR] Generated APIM certificate missing: $EXPECTED" >&2
    exit 1
}

expected="$(
    openssl x509 \
      -in "$EXPECTED" \
      -outform DER |
    shasum -a 256 |
    awk '{print $1}'
)"

live="$(
    openssl s_client \
      -connect "localhost:${PORT}" \
      -servername wso2apim \
      </dev/null 2>/dev/null |
    awk '
      /BEGIN CERTIFICATE/ {capture=1}
      capture {print}
      /END CERTIFICATE/ {exit}
    ' |
    openssl x509 \
      -outform DER 2>/dev/null |
    shasum -a 256 |
    awk '{print $1}'
)"

if [[ -z "$live" ]]; then
    echo "[ERROR] Could not read APIM live TLS certificate" >&2
    exit 1
fi

if [[ "$expected" != "$live" ]]; then
    echo "[ERROR] APIM live TLS certificate does not match generated demo PKI" >&2
    echo "expected=$expected" >&2
    echo "live=$live" >&2
    exit 1
fi

echo "[OK] API Manager live TLS certificate matches generated demo PKI"
