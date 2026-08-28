#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VER="${FS_APIM_MEDIATION_POLICIES_VERSION:-1.0.0}"
MODE="${APIM_POLICIES_SOURCE_MODE:-source}"
REF="${FS_APIM_MEDIATION_POLICIES_GIT_REF:-v${VER}}"
ZIP="dist/fs-apim-mediation-artifacts-${VER}.zip"
CACHE=".cache/financial-services-apim-mediation-policies-${VER}"

mkdir -p dist .cache .cache/m2

if [[ "$MODE" == "local" ]]; then
  [[ -s "$ZIP" ]] && unzip -tq "$ZIP" >/dev/null 2>&1 || {
    echo "ERROR: local APIM mediation artifact is missing or invalid: $ZIP" >&2
    exit 1
  }
  echo "==> Using local Financial Services APIM mediation artifacts ${VER}"
  exit 0
fi

[[ "$MODE" == "source" ]] || {
  echo "ERROR: unsupported APIM_POLICIES_SOURCE_MODE=$MODE (supported: source, local)" >&2
  exit 1
}

if [[ -s "$ZIP" ]] && unzip -tq "$ZIP" >/dev/null 2>&1; then
  echo "==> Financial Services APIM mediation artifacts ${VER} already present"
  exit 0
fi

if [[ ! -d "$CACHE/.git" ]]; then
  rm -rf "$CACHE"
  echo "==> Cloning Financial Services APIM mediation policies ${REF}"
  git clone --depth 1 --branch "$REF" \
    https://github.com/wso2/financial-services-apim-mediation-policies.git \
    "$CACHE"
fi

echo "==> Building APIM mediation artifacts only"
docker run --rm \
  -v "$PWD/$CACHE:/workspace" \
  -v "$PWD/.cache/m2:/root/.m2" \
  -w /workspace \
  maven:3.9.9-eclipse-temurin-17 \
  mvn -B -DskipTests clean install

FOUND="$(find "$CACHE/fs-apim-mediation-artifacts/target" \
  -maxdepth 1 -type f -name "fs-apim-mediation-artifacts-${VER}*.zip" \
  -print -quit || true)"

[[ -n "$FOUND" ]] || {
  echo "ERROR: mediation artifacts ZIP not produced"
  exit 2
}

cp "$FOUND" "$ZIP"
unzip -tq "$ZIP" >/dev/null

echo "==> Prepared $ZIP"
