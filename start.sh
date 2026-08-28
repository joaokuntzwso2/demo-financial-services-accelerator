#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")" && pwd)"; cd "$ROOT"
[[ -f .env ]] || cp .env.example .env
chmod 600 .env 2>/dev/null || true
chmod 600 .env 2>/dev/null || true
source scripts/common.sh
./scripts/check-prereqs.sh
./scripts/generate-certs.sh
./scripts/prepare-dependencies.sh
./scripts/prepare-accelerators.sh
./scripts/prepare-apim-policies.sh
log "Building Go backend, Identity Server 7.2 + IAM Accelerator, API Manager 4.6 + Financial Services mediation policies, and bootstrap helper"
docker compose build bank-backend wso2is wso2apim bootstrap
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
docker compose --profile tools run --rm bootstrap
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
