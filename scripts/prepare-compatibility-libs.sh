#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APIM_VERSION="${APIM_VERSION:-4.6.0}"
IS_VERSION="${IS_VERSION:-7.2.0}"
FS_VERSION="${FS_ACCELERATOR_VERSION:-4.0.0}"
IS7_KM_VERSION="2.0.8"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$APIM_VERSION" == "4.6.0" ]] ||
  fail "Compatibility artifacts are pinned to APIM 4.6.0, got $APIM_VERSION"

[[ "$IS_VERSION" == "7.2.0" ]] ||
  fail "Compatibility artifacts are pinned to IS 7.2.0, got $IS_VERSION"

[[ "$FS_VERSION" == "4.0.0" ]] ||
  fail "Compatibility artifacts are pinned to Financial Services Accelerator 4.0.0, got $FS_VERSION"

VENDOR="$ROOT/vendor/compat"

required=(
  "$VENDOR/apim/wso2is7.key.manager_${IS7_KM_VERSION}.jar"
  "$VENDOR/apim/org.wso2.financial.services.accelerator.common-${FS_VERSION}.jar"
  "$VENDOR/apim/org.wso2.financial.services.accelerator.keymanager-${FS_VERSION}.jar"
  "$VENDOR/is/org.wso2.financial.services.accelerator.identity.extensions-${FS_VERSION}.jar"
  "$VENDOR/SHA256SUMS"
)

for f in "${required[@]}"; do
  [[ -s "$f" ]] || fail "Required compatibility artifact missing: $f"
done

echo "==> Verifying pinned APIM/IS Financial Services compatibility artifacts"

while read -r expected relative; do
  [[ -n "${expected:-}" && -n "${relative:-}" ]] || continue

  actual="$(
    openssl dgst -sha256 "$VENDOR/$relative" |
      awk '{print $NF}'
  )"

  [[ "$actual" == "$expected" ]] ||
    fail "Checksum mismatch for vendor/compat/$relative"
done < "$VENDOR/SHA256SUMS"

# Generated Docker-build inputs.
# Remove any stale experimental artifacts and recreate deterministically.
rm -rf \
  dist/custom-apim-libs \
  dist/fs-apim-accelerator-libs \
  dist/fs-is-accelerator-libs

mkdir -p \
  dist/custom-apim-libs \
  dist/fs-apim-accelerator-libs \
  dist/fs-is-accelerator-libs

cp \
  "$VENDOR/apim/wso2is7.key.manager_${IS7_KM_VERSION}.jar" \
  "dist/custom-apim-libs/wso2is7.key.manager_${IS7_KM_VERSION}.jar"

cp \
  "$VENDOR/apim/org.wso2.financial.services.accelerator.common-${FS_VERSION}.jar" \
  dist/fs-apim-accelerator-libs/

cp \
  "$VENDOR/apim/org.wso2.financial.services.accelerator.keymanager-${FS_VERSION}.jar" \
  dist/fs-apim-accelerator-libs/

cp \
  "$VENDOR/is/org.wso2.financial.services.accelerator.identity.extensions-${FS_VERSION}.jar" \
  dist/fs-is-accelerator-libs/

# This bundle must NOT be installed into APIM 4.6.
if find dist/fs-apim-accelerator-libs \
  -type f \
  -name '*accelerator.gateway*.jar' \
  | grep -q .; then
  fail "Incompatible Financial Services gateway bundle was staged"
fi

echo "[OK] Compatibility artifacts prepared"
