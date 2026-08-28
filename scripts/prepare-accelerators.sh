#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VER="${FS_ACCELERATOR_VERSION:-4.0.0}"
MODE="${ACCELERATOR_SOURCE_MODE:-release}"
ZIP="dist/wso2-fsiam-accelerator-${VER}.zip"
TMP="${ZIP}.part"

mkdir -p dist

if [[ "$MODE" == "local" ]]; then
  [[ -s "$ZIP" ]] && unzip -tq "$ZIP" >/dev/null 2>&1 || {
    echo "ERROR: local IAM Accelerator artifact is missing or invalid: $ZIP" >&2
    exit 1
  }
  echo "==> Using local WSO2 Financial Services IAM Accelerator ${VER}"
  exit 0
fi

[[ "$MODE" == "release" ]] || {
  echo "ERROR: unsupported ACCELERATOR_SOURCE_MODE=$MODE (supported: release, local)" >&2
  exit 1
}

if [[ -s "$ZIP" ]] && unzip -tq "$ZIP" >/dev/null 2>&1; then
  echo "==> WSO2 Financial Services IAM Accelerator ${VER} already present"
  exit 0
fi

rm -f "$ZIP" "$TMP"

URL="https://github.com/wso2/financial-services-accelerator/releases/download/v${VER}/wso2-fsiam-accelerator-${VER}.zip"

echo "==> Downloading official WSO2 Financial Services IAM Accelerator ${VER}"
curl -fL --retry 5 --retry-delay 3 "$URL" -o "$TMP"

unzip -tq "$TMP" >/dev/null || {
  rm -f "$TMP"
  echo "ERROR: downloaded Accelerator ZIP failed validation"
  exit 1
}

mv "$TMP" "$ZIP"
echo "==> Prepared $ZIP"
