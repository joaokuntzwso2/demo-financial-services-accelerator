#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")" && pwd)"; cd "$ROOT"
[[ -f .env ]] || cp .env.example .env
chmod 600 .env 2>/dev/null || true
chmod 600 .env 2>/dev/null || true
source scripts/common.sh
./scripts/check-prereqs.sh

START_MODE="${1:---fresh}"

case "$START_MODE" in
  --fresh)
    ./scripts/clean-demo-environment.sh
    ;;
  --reuse)
    log "Reusing existing demo runtime state"
    ;;
  *)
    echo "Usage: ./start.sh [--fresh|--reuse]" >&2
    echo >&2
    echo "  --fresh  Remove previous demo runtime state before startup (default)" >&2
    echo "  --reuse  Keep the existing database and generated state" >&2
    exit 2
    ;;
esac

./scripts/generate-certs.sh
./scripts/prepare-dependencies.sh
./scripts/prepare-accelerators.sh
./scripts/prepare-compatibility-libs.sh
./scripts/prepare-apim-policies.sh
log "Building Go backend, Identity Server 7.2 + IAM Accelerator, API Manager 4.6 + Financial Services mediation policies, and bootstrap helper"
docker compose build mysql bank-backend wso2is wso2apim bootstrap
log "Starting database and bank backend"
docker compose up -d mysql bank-backend
retry "docker compose exec -T mysql mysqladmin ping -h127.0.0.1 -uroot -p${MYSQL_ROOT_PASSWORD:-root} --silent" 60 || fatal "MySQL did not become healthy"
./scripts/init-db.sh
log "Starting Identity Server"
docker compose up -d wso2is
retry "curl -ksSf https://localhost:${IS_HTTPS_PORT:-9446}/oauth2/jwks >/dev/null" 100 || { docker compose logs --tail=200 wso2is; fatal "IS failed to start"; }
log "Starting API Manager"
docker compose up -d wso2apim
./scripts/wait-products.sh
./scripts/extract-policies.sh
log "Bootstrapping IS/APIM integration, APIs, policies, revisions and publication"
mkdir -p .state/bootstrap

BOOTSTRAP_CONTAINER="$(
  docker compose --profile tools run \
    -d \
    --no-deps \
    --entrypoint sh \
    bootstrap \
    -c 'sleep 3600'
)"

bootstrap_cleanup() {
  docker rm -f "$BOOTSTRAP_CONTAINER" >/dev/null 2>&1 || true
}

trap bootstrap_cleanup EXIT

docker exec "$BOOTSTRAP_CONTAINER" \
  mkdir -p /workspace/apis /workspace/policies /workspace/state

docker cp \
  "$ROOT/apis/." \
  "$BOOTSTRAP_CONTAINER:/workspace/apis/"

docker cp \
  "$ROOT/.state/policies/." \
  "$BOOTSTRAP_CONTAINER:/workspace/policies/"

if find "$ROOT/.state/bootstrap" -mindepth 1 -print -quit | grep -q .; then
  docker cp \
    "$ROOT/.state/bootstrap/." \
    "$BOOTSTRAP_CONTAINER:/workspace/state/"
fi

BOOTSTRAP_RC=0

docker exec \
  "$BOOTSTRAP_CONTAINER" \
  /opt/bootstrap/bootstrap.sh \
  || BOOTSTRAP_RC=$?

rm -rf "$ROOT/.state/bootstrap"
mkdir -p "$ROOT/.state/bootstrap"

docker cp \
  "$BOOTSTRAP_CONTAINER:/workspace/state/." \
  "$ROOT/.state/bootstrap/" \
  >/dev/null 2>&1 || true

bootstrap_cleanup
trap - EXIT

[[ "$BOOTSTRAP_RC" -eq 0 ]] \
  || fatal "IS/APIM bootstrap failed"

# Bootstrap demo identities, APIM application, subscriptions, keys and RBAC.
echo
echo "==> Bootstrapping demo users and API access"
./scripts/bootstrap-demo-access.sh .
./scripts/verify.sh
cat <<EOF

Demo is ready.
  APIM Publisher:       https://localhost:${APIM_HTTPS_PORT:-9443}/publisher
  APIM DeveloperPortal: https://localhost:${APIM_HTTPS_PORT:-9443}/devportal
  APIM Admin:           https://localhost:${APIM_HTTPS_PORT:-9443}/admin
  Identity Server:      https://localhost:${IS_HTTPS_PORT:-9446}/console
  Gateway:              https://localhost:${APIM_GATEWAY_HTTPS_PORT:-8243}
  Mock bank:            http://localhost:${BANK_BACKEND_PORT:-8080}/demo/summary

Next: ./demo/run.sh
EOF
