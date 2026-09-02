#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

wait_health() {
  local container="$1"
  local i status

  for i in $(seq 1 120); do
    status="$(
      docker inspect \
        -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$container" 2>/dev/null || true
    )"

    if [[ "$status" == "healthy" ]]; then
      echo "[OK] $container healthy"
      return 0
    fi

    sleep 2
  done

  die "$container did not become healthy"
}

trust_demo_ca_in_apim() {
  local container="${APIM_CONTAINER:-wso2-ob-apim}"
  local ca=".state/certs/ca.crt"
  local home truststore alias="demo-root-ca"

  [[ -s "$ca" ]] || die "missing $ca"

  home="$(
    docker exec "$container" sh -lc \
      'printf "%s" "${WSO2_SERVER_HOME:-}"' 2>/dev/null || true
  )"
  [[ -n "$home" ]] ||
    home="/home/wso2carbon/wso2am-4.6.0"

  truststore="$home/repository/resources/security/client-truststore.jks"

  if docker exec "$container" keytool \
      -list \
      -alias "$alias" \
      -keystore "$truststore" \
      -storepass wso2carbon >/dev/null 2>&1; then
    echo "[OK] APIM already trusts Demo Root CA"
    return
  fi

  docker cp \
    "$ca" \
    "$container:/tmp/demo-root-ca.crt" >/dev/null

  docker exec -u root "$container" keytool \
    -importcert \
    -noprompt \
    -alias "$alias" \
    -file /tmp/demo-root-ca.crt \
    -keystore "$truststore" \
    -storepass wso2carbon >/dev/null

  docker exec -u root "$container" \
    rm -f /tmp/demo-root-ca.crt

  docker compose restart wso2apim >/dev/null
  wait_health "$container"

  echo "[OK] Demo Root CA imported into APIM client truststore"
}

for c in docker curl jq grep; do
  command -v "$c" >/dev/null 2>&1 ||
    die "$c is required"
done

for cert in \
  .state/certs/ca.crt \
  .state/certs/directory.crt \
  .state/certs/directory.key \
  .state/certs/tpp.crt \
  .state/certs/tpp.key
do
  [[ -s "$cert" ]] ||
    die "missing generated PKI material: $cert"
done

echo
echo "============================================================"
echo "1. BUILD DCR-CAPABLE RUNTIME"
echo "============================================================"

docker compose build \
  bank-backend \
  wso2is \
  wso2apim

echo
echo "============================================================"
echo "2. RECREATE BANK DIRECTORY SERVICE"
echo "============================================================"

docker compose up \
  -d \
  --no-deps \
  --force-recreate \
  bank-backend

wait_health wso2-ob-bank-backend

echo
echo "============================================================"
echo "3. RECREATE IS + APIM WITH DCR CONFIG"
echo "============================================================"

docker compose up \
  -d \
  --no-deps \
  --force-recreate \
  wso2is \
  wso2apim

wait_health wso2-ob-is
wait_health wso2-ob-apim

trust_demo_ca_in_apim

echo
echo "============================================================"
echo "4. DIRECTORY JWKS — HOST"
echo "============================================================"

DIRECTORY_JWKS="$(
  curl -fsS \
    "http://localhost:${BANK_BACKEND_PORT:-8080}/directory/jwks.json"
)"

printf '%s\n' "$DIRECTORY_JWKS" | jq .

[[ "$(
  printf '%s' "$DIRECTORY_JWKS" |
  jq '.keys | length'
)" == "1" ]] ||
  die "directory JWKS must expose exactly one signing key"

printf '%s' "$DIRECTORY_JWKS" |
  jq -e '
    .keys[0]
    | .kty == "RSA"
      and .use == "sig"
      and .alg == "PS256"
      and (.kid | length > 0)
      and (.n | length > 0)
      and (.e | length > 0)
      and (has("d") | not)
  ' >/dev/null ||
  die "directory JWKS is not a public-only PS256 RSA key"

echo "[OK] real directory public key exposed"

echo
echo "============================================================"
echo "5. FINLINK SOFTWARE JWKS — HOST"
echo "============================================================"

SOFTWARE_JWKS="$(
  curl -fsS \
    "http://localhost:${BANK_BACKEND_PORT:-8080}/directory/software/finlink/jwks.json"
)"

printf '%s\n' "$SOFTWARE_JWKS" | jq .

[[ "$(
  printf '%s' "$SOFTWARE_JWKS" |
  jq '.keys | length'
)" == "1" ]] ||
  die "software JWKS must expose exactly one signing key"

printf '%s' "$SOFTWARE_JWKS" |
  jq -e '
    .keys[0]
    | .kty == "RSA"
      and .use == "sig"
      and .alg == "PS256"
      and (.kid | length > 0)
      and (.n | length > 0)
      and (.e | length > 0)
      and (has("d") | not)
  ' >/dev/null ||
  die "software JWKS is not a public-only PS256 RSA key"

echo "[OK] real FinLink software public key exposed"

echo
echo "============================================================"
echo "6. JWKS REACHABILITY FROM IDENTITY SERVER"
echo "============================================================"

docker compose exec -T wso2is \
  curl -fsS \
  http://bank-backend:8080/directory/jwks.json |
  jq -e '.keys | length == 1' >/dev/null

docker compose exec -T wso2is \
  curl -fsS \
  http://bank-backend:8080/directory/software/finlink/jwks.json |
  jq -e '.keys | length == 1' >/dev/null

echo "[OK] IS can retrieve both directory and software JWKS"

echo
echo "============================================================"
echo "7. EFFECTIVE IS DCR CONFIG"
echo "============================================================"

docker compose exec -T wso2is sh -lc '
  HOME_DIR="${WSO2_SERVER_HOME:-/home/wso2carbon/wso2is-7.2.0}"
  CONF="$HOME_DIR/repository/conf/deployment.toml"
  grep -n -A12 -B2 -E \
    "^\[oauth\.dcr\]|ssa_jkws|ssa_jwks|enable_fapi_enforcement|open_banking\.dcr\.regulatory_issuers|OpenBanking Ltd" \
    "$CONF"
'

docker compose exec -T wso2is sh -lc '
  HOME_DIR="${WSO2_SERVER_HOME:-/home/wso2carbon/wso2is-7.2.0}"
  CONF="$HOME_DIR/repository/conf/deployment.toml"
  grep -q "ssa_jkws = \"http://bank-backend:8080/directory/jwks.json\"" "$CONF"
  grep -q "enable_fapi_enforcement = true" "$CONF"
  grep -q "name = \"OpenBanking Ltd\"" "$CONF"
'

echo "[OK] real SSA trust + regulatory issuer loaded"

echo
echo "============================================================"
echo "8. EFFECTIVE APIM OOB CONFIG"
echo "============================================================"

docker compose exec -T wso2apim sh -lc '
  HOME_DIR="${WSO2_SERVER_HOME:-/home/wso2carbon/wso2am-4.6.0}"
  CONF="$HOME_DIR/repository/conf/deployment.toml"
  grep -n -A6 -B2 -E \
    "^\[apim\.devportal\]|enable_key_provisioning" \
    "$CONF"
  grep -q "enable_key_provisioning = true" "$CONF"
'

echo "[OK] out-of-band key provisioning enabled"

echo
echo "============================================================"
echo "9. PUBLISH REAL DCR API"
echo "============================================================"

./scripts/publish-dcr-api.sh

echo
echo "============================================================"
echo "10. PUBLIC DCR SURFACE"
echo "============================================================"

HTTP="$(
  curl -sS \
    --cacert .state/certs/ca.crt \
    --cert .state/certs/tpp.crt \
    --key .state/certs/tpp.key \
    -o /tmp/dcr-surface-probe.txt \
    -w '%{http_code}' \
    "https://localhost:${APIM_GATEWAY_HTTPS_PORT:-8243}/open-banking/v3.3.0/register" \
    || true
)"

echo "HTTP=$HTTP"
head -c 800 /tmp/dcr-surface-probe.txt 2>/dev/null || true
echo

[[ "$HTTP" != "000" ]] ||
  die "DCR surface is unreachable"

[[ "$HTTP" != "404" ]] ||
  die "DCR API is not deployed at /open-banking/v3.3.0/register"

echo
echo "============================================================"
echo "DCR ACT 0 RUNTIME PREPARATION PASSED"
echo "============================================================"
echo "[OK] no database reset performed"
echo "[OK] directory JWKS is cryptographically real"
echo "[OK] FinLink software JWKS is cryptographically real"
echo "[OK] IS trusts the configured local directory"
echo "[OK] APIM supports OOB mapping for the DCR-created client"
echo
echo "Next:"
echo "  ./demo/tpp-onboarding.sh --fresh"
