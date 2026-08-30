#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VER="${FS_APIM_MEDIATION_POLICIES_VERSION:-1.0.0}"
MODE="${APIM_POLICIES_SOURCE_MODE:-source}"
REF="${FS_APIM_MEDIATION_POLICIES_GIT_REF:-v${VER}}"

ZIP="dist/fs-apim-mediation-artifacts-${VER}.zip"
CACHE=".cache/financial-services-apim-mediation-policies-${VER}"

mkdir -p dist .cache

if [[ "$MODE" == "local" ]]; then
    if [[ ! -s "$ZIP" ]] || ! unzip -tq "$ZIP" >/dev/null 2>&1; then
        echo "ERROR: local APIM mediation artifact is missing or invalid: $ZIP" >&2
        exit 1
    fi

    echo "==> Using local Financial Services APIM mediation artifacts ${VER}"
    exit 0
fi

if [[ "$MODE" != "source" ]]; then
    echo "ERROR: unsupported APIM_POLICIES_SOURCE_MODE=$MODE (supported: source, local)" >&2
    exit 1
fi

if [[ -s "$ZIP" ]] && unzip -tq "$ZIP" >/dev/null 2>&1; then
    echo "==> Financial Services APIM mediation artifacts ${VER} already present"
    exit 0
fi

if [[ ! -d "$CACHE/.git" ]]; then
    rm -rf "$CACHE"

    echo "==> Cloning Financial Services APIM mediation policies ${REF}"

    git clone \
        --depth 1 \
        --branch "$REF" \
        https://github.com/wso2/financial-services-apim-mediation-policies.git \
        "$CACHE"
fi

CONTAINER="wso2-ob-apim-policy-build-${PPID}-$$-${RANDOM}"

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "==> Preparing isolated Maven build container"

docker create \
    --name "$CONTAINER" \
    maven:3.9.9-eclipse-temurin-17 \
    sh -c 'mkdir -p /workspace && sleep 3600' \
    >/dev/null

docker start "$CONTAINER" >/dev/null

echo "==> Copying mediation-policy source into build container"

docker cp \
    "$CACHE/." \
    "$CONTAINER:/workspace/"

echo "==> Building APIM mediation modules and artifacts"

docker exec "$CONTAINER" bash -lc '
set -Eeuo pipefail

cd /workspace

echo "==> Discovering Financial Services mediation Java modules"

mapfile -t mediation_poms < <(
    find common open-banking-uk \
        -type f \
        -name pom.xml \
        -print \
        | sort \
        | while read -r pom; do
            module_dir="$(dirname "$pom")"

            if [[ -d "$module_dir/src/main/java" ]]; then
                printf "%s\n" "$pom"
            fi
          done
)

if [[ "${#mediation_poms[@]}" -eq 0 ]]; then
    echo "ERROR: no mediation Java modules discovered" >&2
    exit 1
fi

echo "==> Found ${#mediation_poms[@]} mediator modules"

for pom in "${mediation_poms[@]}"; do
    echo
    echo "==> Building $pom"

    mvn \
        -B \
        -DskipTests \
        -f "$pom" \
        clean install
done

echo
echo "==> Building fs-apim-mediation-artifacts"

mvn \
    -B \
    -DskipTests \
    -f fs-apim-mediation-artifacts/pom.xml \
    clean install
'

FOUND="$(
    docker exec "$CONTAINER" sh -c \
        "find /workspace/fs-apim-mediation-artifacts/target \
         -maxdepth 1 \
         -type f \
         -name 'fs-apim-mediation-artifacts-${VER}*.zip' \
         -print -quit"
)"

if [[ -z "$FOUND" ]]; then
    echo "ERROR: mediation artifacts ZIP not produced" >&2
    exit 2
fi

echo "==> Copying generated mediation artifact"

rm -f "$ZIP"

docker cp \
    "$CONTAINER:$FOUND" \
    "$ZIP"

cleanup
trap - EXIT

unzip -tq "$ZIP" >/dev/null

echo "==> Prepared $ZIP"
