#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

STATE_DIR=".state/dcr"
ACCESS_STATE=".state/demo-access"

REGISTRATION_FILE="$STATE_DIR/finlink-registration.json"
SUMMARY_FILE="$STATE_DIR/onboarding-summary.json"
SSA_FILE="$STATE_DIR/finlink-ssa.jwt"
SSA_PAYLOAD_FILE="$STATE_DIR/finlink-ssa-payload.json"
REG_REQUEST_FILE="$STATE_DIR/registration-request.jwt"
REG_PAYLOAD_FILE="$STATE_DIR/registration-request-payload.json"
UPDATE_REQUEST_FILE="$STATE_DIR/registration-update.jwt"
UPDATE_PAYLOAD_FILE="$STATE_DIR/registration-update-payload.json"
TOKEN_FILE="$STATE_DIR/application-token.json"
SIGNER="$STATE_DIR/dcrsign"

IS_URL="${IS_PUBLIC:-https://localhost:${IS_HTTPS_PORT:-9446}}"
APIM_URL="${APIM_PUBLIC:-https://localhost:${APIM_HTTPS_PORT:-9443}}"
GW_URL="${GW_PUBLIC:-https://localhost:${APIM_GATEWAY_HTTPS_PORT:-8243}}"
DCR_URL="${DCR_URL:-$GW_URL/open-banking/v3.3.0/register}"
BANK_URL="${BANK_PUBLIC:-http://localhost:${BANK_BACKEND_PORT:-8080}}"

CA=".state/certs/ca.crt"
TPP_CERT=".state/certs/tpp.crt"
TPP_KEY=".state/certs/tpp.key"
DIRECTORY_CERT=".state/certs/directory.crt"
DIRECTORY_KEY=".state/certs/directory.key"

DIRECTORY_ISSUER="${DCR_DIRECTORY_ISSUER:-OpenBanking Ltd}"
SOFTWARE_ID="${DCR_SOFTWARE_ID:-FinLinkDemoSoftware01}"
SOFTWARE_NAME="${DCR_SOFTWARE_NAME:-FinLink}"
DCR_AUDIENCE="${DCR_AUDIENCE:-https://localbank.com}"
REDIRECT_URI="${DCR_REDIRECT_URI:-https://localhost:9445/callback}"

DIRECTORY_JWKS_INTERNAL="http://bank-backend:8080/directory/jwks.json"
SOFTWARE_JWKS_INTERNAL="http://bank-backend:8080/directory/software/finlink/jwks.json"

KEY_MANAGER_NAME="${KEY_MANAGER_NAME:-FS-KEY-MANAGER}"

APIM_ADMIN_USER="${APIM_ADMIN_USER:-admin}"
APIM_ADMIN_PASSWORD="${APIM_ADMIN_PASSWORD:-admin}"
IS_ADMIN_USER="${IS_ADMIN_USER:-admin}"
IS_ADMIN_PASSWORD="${IS_ADMIN_PASSWORD:-admin}"

MODE="run"
FRESH=0

case "${1:-}" in
  --fresh)
    FRESH=1
    ;;
  show)
    MODE="show"
    ;;
  -h|--help)
    cat <<'USAGE'
Usage:
  ./demo/tpp-onboarding.sh
  ./demo/tpp-onboarding.sh --fresh
  ./demo/tpp-onboarding.sh show

Default:
  Reuse and verify the existing DCR onboarding if .state/dcr exists.
  If no DCR state exists, create a new onboarding.

--fresh:
  Create a brand-new DCR client. Existing clients are not deleted.

show:
  Render the last non-secret onboarding proof without changing runtime state.
USAGE
    exit 0
    ;;
  "")
    ;;
  *)
    echo "ERROR: unknown argument: $1" >&2
    exit 1
    ;;
esac

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  [[ -s "$1" ]] ||
    die "missing required file: $1"
}

uuid() {
  uuidgen | tr '[:upper:]' '[:lower:]'
}

jwt_payload() {
  local token="$1"

  JWT="$token" python3 - <<'PY'
import base64
import json
import os

token = os.environ["JWT"]
parts = token.split(".")
if len(parts) != 3:
    raise SystemExit("invalid JWT")

part = parts[1]
part += "=" * (-len(part) % 4)

print(
    json.dumps(
        json.loads(
            base64.urlsafe_b64decode(part.encode())
        ),
        separators=(",", ":"),
    )
)
PY
}

jwt_header() {
  local token="$1"

  JWT="$token" python3 - <<'PY'
import base64
import json
import os

token = os.environ["JWT"]
parts = token.split(".")
if len(parts) != 3:
    raise SystemExit("invalid JWT")

part = parts[0]
part += "=" * (-len(part) % 4)

print(
    json.dumps(
        json.loads(
            base64.urlsafe_b64decode(part.encode())
        ),
        separators=(",", ":"),
    )
)
PY
}

token_fingerprint() {
  shasum -a 256 |
    awk '{print substr($1,1,16)}'
}

build_signer() {
  (
    cd demo/dcrsign
    go build -o "$ROOT/$SIGNER" .
  )
}

apim_rest_token() {
  local scopes="$1"
  local purpose="$2"
  local reg="$STATE_DIR/apim-${purpose}-registration.json"
  local tok="$STATE_DIR/apim-${purpose}-token.json"
  local http cid secret

  http="$(
    curl -sS \
      --cacert "$CA" \
      -o "$reg" \
      -w '%{http_code}' \
      -u "${APIM_ADMIN_USER}:${APIM_ADMIN_PASSWORD}" \
      -H 'Content-Type: application/json' \
      -X POST "$APIM_URL/client-registration/v0.17/register" \
      -d "$(
        jq -nc \
          --arg owner "$APIM_ADMIN_USER" \
          --arg name "finlink-act0-${purpose}-$(date +%s)" \
          '{
            callbackUrl:"https://localhost/callback",
            clientName:$name,
            owner:$owner,
            grantType:"password refresh_token",
            saasApp:true
          }'
      )"
  )"

  [[ "$http" == "200" || "$http" == "201" ]] || {
    cat "$reg" >&2 || true
    die "could not create APIM automation client (HTTP $http)"
  }

  cid="$(jq -er '.clientId // .client_id' "$reg")"
  secret="$(jq -er '.clientSecret // .client_secret' "$reg")"

  http="$(
    curl -sS \
      --cacert "$CA" \
      -o "$tok" \
      -w '%{http_code}' \
      -u "${cid}:${secret}" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      -X POST "$APIM_URL/oauth2/token" \
      --data-urlencode 'grant_type=password' \
      --data-urlencode "username=$APIM_ADMIN_USER" \
      --data-urlencode "password=$APIM_ADMIN_PASSWORD" \
      --data-urlencode "scope=$scopes"
  )"

  [[ "$http" == "200" ]] || {
    cat "$tok" >&2 || true
    die "could not obtain APIM automation token (HTTP $http)"
  }

  jq -er '.access_token' "$tok"
}

ensure_apim_application() {
  local dp_token="$1"
  local name="$2"
  local list="$STATE_DIR/apim-applications.json"
  local response="$STATE_DIR/apim-application.json"
  local app_id http

  curl -sS \
    --cacert "$CA" \
    -H "Authorization: Bearer $dp_token" \
    "$APIM_URL/api/am/devportal/v3/applications?limit=100" \
    > "$list"

  app_id="$(
    jq -r \
      --arg n "$name" \
      '(.list // [])[]
       | select(.name==$n)
       | .applicationId' \
      "$list" |
    head -1
  )"

  if [[ -n "$app_id" && "$app_id" != "null" ]]; then
    printf '%s' "$app_id"
    return
  fi

  http="$(
    curl -sS \
      --cacert "$CA" \
      -o "$response" \
      -w '%{http_code}' \
      -H "Authorization: Bearer $dp_token" \
      -H 'Content-Type: application/json' \
      -X POST \
      "$APIM_URL/api/am/devportal/v3/applications" \
      -d "$(
        jq -nc \
          --arg n "$name" \
          '{
            name:$n,
            throttlingPolicy:"Unlimited",
            description:"FinLink client created by Financial Services DCR and mapped by OOB provisioning",
            tokenType:"JWT"
          }'
      )"
  )"

  [[ "$http" == "200" || "$http" == "201" ]] || {
    cat "$response" >&2 || true
    die "could not create DCR-backed APIM application (HTTP $http)"
  }

  jq -er '.applicationId' "$response"
}

map_dcr_client_to_apim() {
  local dp_token="$1"
  local app_id="$2"
  local client_id="$3"
  local client_secret="$4"

  local response="$STATE_DIR/apim-map-keys.json"
  local payload="$STATE_DIR/apim-map-keys-request.json"
  local list="$STATE_DIR/apim-oauth-keys.json"
  local selected="$STATE_DIR/apim-oauth-key-selected.json"
  local detail="$STATE_DIR/apim-oauth-key-detail.json"

  local http lookup_http detail_http mapping_id

  jq -nc \
    --arg ck "$client_id" \
    --arg cs "$client_secret" \
    --arg km "$KEY_MANAGER_NAME" '
    {
      consumerKey:$ck,
      consumerSecret:$cs,
      keyManager:$km,
      keyType:"PRODUCTION"
    }
  ' > "$payload"

  chmod 600 "$payload" 2>/dev/null || true

  http="$(
    curl -sS \
      --cacert "$CA" \
      -o "$response" \
      -w '%{http_code}' \
      -H "Authorization: Bearer $dp_token" \
      -H 'Content-Type: application/json' \
      -X POST \
      "$APIM_URL/api/am/devportal/v3/applications/$app_id/map-keys" \
      --data-binary @"$payload"
  )"

  if [[ "$http" == "200" || "$http" == "201" ]]; then

    echo "[OK] DCR client mapping created in APIM"

  elif [[ "$http" == "409" ]]; then

    echo "[RESUME] APIM reports that a key mapping already exists"
    echo "[RESUME] Verifying that it belongs to the same DCR client"

    lookup_http="$(
      curl -sS \
        --cacert "$CA" \
        -o "$list" \
        -w '%{http_code}' \
        -H "Authorization: Bearer $dp_token" \
        "$APIM_URL/api/am/devportal/v3/applications/$app_id/oauth-keys"
    )"

    [[ "$lookup_http" == "200" ]] ||
      die "could not inspect existing APIM OAuth mappings (HTTP $lookup_http)"

    jq \
      --arg km "$KEY_MANAGER_NAME" \
      --arg ck "$client_id" '
        [
          (.list // [])[]
          | select(
              .keyType == "PRODUCTION"
              and .keyManager == $km
              and .consumerKey == $ck
            )
        ]
        | .[0] // empty
      ' "$list" > "$selected"

    mapping_id="$(
      jq -r \
        '.keyMappingId // empty' \
        "$selected"
    )"

    [[ -n "$mapping_id" ]] ||
      die "APIM returned 409 but no existing mapping matches the DCR client"

    detail_http="$(
      curl -sS \
        --cacert "$CA" \
        -o "$detail" \
        -w '%{http_code}' \
        -H "Authorization: Bearer $dp_token" \
        "$APIM_URL/api/am/devportal/v3/applications/$app_id/oauth-keys/$mapping_id"
    )"

    [[ "$detail_http" == "200" ]] ||
      die "could not read existing APIM OAuth mapping $mapping_id (HTTP $detail_http)"

    jq -e \
      --arg mapping "$mapping_id" \
      --arg ck "$client_id" '
        .keyMappingId == $mapping
        and .consumerKey == $ck
        and .keyType == "PRODUCTION"
        and .mode == "MAPPED"
      ' "$detail" >/dev/null ||
      die "existing APIM key mapping detail does not match the selected DCR mapping"

    echo "[OK] Existing APIM mapping verified for the same DCR client"

  else

    echo "APIM OOB mapping response:" >&2
    cat "$response" >&2 || true
    die "mapping DCR client into APIM failed (HTTP $http)"

  fi

  mkdir -p "$ACCESS_STATE"

  jq -nc \
    --arg app "$app_id" \
    --arg km "$KEY_MANAGER_NAME" \
    --arg key "$client_id" \
    --arg secret "$client_secret" '
    {
      applicationId:$app,
      keyManager:$km,
      consumerKey:$key,
      consumerSecret:$secret,
      source:"Financial Services DCR + APIM OOB mapping"
    }
  ' > "$ACCESS_STATE/application-keys.json"

  chmod 600 \
    "$ACCESS_STATE/application-keys.json" \
    2>/dev/null || true
}

resolve_is_application() {
  local client_id="$1"
  local response="$STATE_DIR/is-application-search.json"

  curl -sS \
    --cacert "$CA" \
    -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
    -G "$IS_URL/api/server/v1/applications" \
    --data-urlencode "filter=clientId eq $client_id" \
    --data-urlencode 'attributes=clientId,associatedRoles.allowedAudience' \
    > "$response"

  jq -er '.applications[0].id' "$response"
}

issue_application_token() {
  local client_id="$1"
  local http

  http="$(
    curl -sS \
      --cacert "$CA" \
      --cert "$TPP_CERT" \
      --key "$TPP_KEY" \
      -o "$TOKEN_FILE" \
      -w '%{http_code}' \
      -X POST "$IS_URL/oauth2/token" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode 'grant_type=client_credentials' \
      --data-urlencode "client_id=$client_id" \
      --data-urlencode 'scope=accounts'
  )"

  [[ "$http" == "200" ]] || {
    cat "$TOKEN_FILE" >&2 || true
    die "DCR client could not obtain certificate-bound application token (HTTP $http)"
  }

  chmod 600 "$TOKEN_FILE" 2>/dev/null || true

  jq -e '.access_token' "$TOKEN_FILE" >/dev/null ||
    die "token response has no access_token"
}

dcr_read() {
  local client_id="$1"
  local access_token="$2"
  local out="$3"
  local http

  http="$(
    curl -sS \
      --cacert "$CA" \
      --cert "$TPP_CERT" \
      --key "$TPP_KEY" \
      -o "$out" \
      -w '%{http_code}' \
      -H "Authorization: Bearer $access_token" \
      -H 'Accept: application/json' \
      "$DCR_URL/$client_id"
  )"

  [[ "$http" == "200" ]] || {
    cat "$out" >&2 || true
    die "DCR read failed for client $client_id (HTTP $http)"
  }
}

render_summary() {
  [[ -s "$SUMMARY_FILE" ]] ||
    die "$SUMMARY_FILE does not exist; run onboarding first"

  echo
  echo "============================================================"
  echo "ACT 0 — TPP ONBOARDING"
  echo "============================================================"

  jq -r '
    "Directory             \(.directory.label)",
    "Directory issuer      \(.directory.issuer)",
    "SSA alg / kid         \(.ssa.alg) / \(.ssa.kid)",
    "Software ID           \(.software.id)",
    "Software roles        \(.software.roles | join(", "))",
    "Software JWKS         \(.software.jwks_uri)",
    "Registration alg/kid  \(.registration.alg) / \(.registration.kid)",
    "DCR endpoint          \(.registration.endpoint)",
    "Client ID             \(.client.id)",
    "Redirect URI          \(.client.redirect_uri)",
    "Grant profile         \(.client.grant_types | join(", "))",
    "Token auth            \(.client.token_endpoint_auth_method)",
    "Cert-bound tokens     \(.client.tls_client_certificate_bound_access_tokens)",
    "Signed req objects    \(.client.require_signed_request_object)",
    "TPP certificate       \(.transport.subject)",
    "TPP cert SHA-256      \(.transport.sha256_fingerprint)",
    "IS application        \(.client.is_application_id)",
    "APIM application      \(.apim.name) (\(.apim.application_id))",
    "API subscriptions     \(.apim.subscription_count)",
    (if .proof.create_mode == "created" then
       "DCR create            HTTP \(.proof.create_http)"
     else
       "DCR registration      reused existing client (no CREATE)"
     end),
    "DCR read              HTTP \(.proof.read_http)",
    "DCR update            HTTP \(.proof.update_http)",
    "FinLink client match  \(.proof.finlink_client_match)"
  ' "$SUMMARY_FILE"

  echo
  echo "[NOTE] The directory is a local cryptographic simulator, not a real"
  echo "       regulatory directory. SSA signing, JWKS verification, mTLS,"
  echo "       DCR client creation, APIM OOB mapping and WSO2 authorization are real."
  echo
  echo "[NOTE] This demo reuses one generated FinLink RSA certificate/key pair for"
  echo "       software signing and mTLS transport. Production deployments should"
  echo "       follow the applicable directory/regulatory key separation model."
  echo
  echo "[OK] TPP ONBOARDING PASSED"
}

for c in \
  curl \
  jq \
  openssl \
  go \
  python3 \
  uuidgen \
  shasum
do
  command -v "$c" >/dev/null 2>&1 ||
    die "$c is required"
done

for f in \
  "$CA" \
  "$TPP_CERT" \
  "$TPP_KEY" \
  "$DIRECTORY_CERT" \
  "$DIRECTORY_KEY"
do
  require_file "$f"
done


DCR_SURFACE_HTTP="$(
  curl -sS \
    --cacert "$CA" \
    --cert "$TPP_CERT" \
    --key "$TPP_KEY" \
    -o /tmp/finlink-dcr-preflight.json \
    -w '%{http_code}' \
    -X POST "$DCR_URL" \
    -H 'Content-Type: application/jwt' \
    --data-binary 'not-a-valid-jwt' \
    || true
)"

[[ "$DCR_SURFACE_HTTP" != "000" && "$DCR_SURFACE_HTTP" != "404" ]] ||
  die "DCR API is not published at $DCR_URL; run ./scripts/publish-dcr-api.sh"

if [[ "$MODE" == "show" ]]; then
  render_summary
  exit 0
fi

if [[ \
  "$FRESH" == "0" \
  && -s "$REGISTRATION_FILE" \
  && -s "$SUMMARY_FILE" \
]]; then
  CLIENT_ID="$(jq -er '.client_id' "$REGISTRATION_FILE")"

  echo
  echo "============================================================"
  echo "REUSE EXISTING DCR ONBOARDING"
  echo "============================================================"
  echo "Client ID: $CLIENT_ID"

  issue_application_token "$CLIENT_ID"
  ACCESS_TOKEN="$(jq -er '.access_token' "$TOKEN_FILE")"

  dcr_read \
    "$CLIENT_ID" \
    "$ACCESS_TOKEN" \
    "$STATE_DIR/reuse-read.json"

  ./demo/finlink.sh restart --no-open >/dev/null

  FINLINK_CLIENT="$(
    curl -fsS \
      --cacert "$CA" \
      https://localhost:9445/healthz |
    jq -er '.client_id'
  )"

  [[ "$FINLINK_CLIENT" == "$CLIENT_ID" ]] ||
    die "FinLink is not using the existing DCR client; run --fresh to establish a new onboarding"

  render_summary
  exit 0
fi

build_signer

echo
echo "============================================================"
echo "1. VERIFY DIRECTORY + SOFTWARE JWKS"
echo "============================================================"

DIRECTORY_JWKS="$(
  curl -fsS \
    "$BANK_URL/directory/jwks.json"
)"

SOFTWARE_JWKS="$(
  curl -fsS \
    "$BANK_URL/directory/software/finlink/jwks.json"
)"

DIR_KID="$(
  "$SIGNER" kid \
    --cert "$DIRECTORY_CERT"
)"

TPP_KID="$(
  "$SIGNER" kid \
    --cert "$TPP_CERT"
)"

[[ "$(
  printf '%s' "$DIRECTORY_JWKS" |
  jq -r '.keys[0].kid'
)" == "$DIR_KID" ]] ||
  die "directory JWKS kid does not match directory certificate"

[[ "$(
  printf '%s' "$SOFTWARE_JWKS" |
  jq -r '.keys[0].kid'
)" == "$TPP_KID" ]] ||
  die "software JWKS kid does not match FinLink certificate"

echo "Directory kid: $DIR_KID"
echo "Software kid : $TPP_KID"
echo "[OK] both JWKS endpoints contain the expected public keys"

echo
echo "============================================================"
echo "2. CREATE FINLINK SOFTWARE STATEMENT ASSERTION"
echo "============================================================"

NOW="$(date +%s)"
EXP="$((NOW + 3600))"

jq -nc \
  --arg iss "$DIRECTORY_ISSUER" \
  --arg software_id "$SOFTWARE_ID" \
  --arg software_name "$SOFTWARE_NAME" \
  --arg redirect "$REDIRECT_URI" \
  --arg directory_jwks "$DIRECTORY_JWKS_INTERNAL" \
  --arg software_jwks "$SOFTWARE_JWKS_INTERNAL" \
  --arg jti "$(uuid)" \
  --argjson iat "$NOW" \
  --argjson exp "$EXP" '
  {
    iss:$iss,
    iat:$iat,
    exp:$exp,
    jti:$jti,
    software_environment:"sandbox",
    software_mode:"Test",
    software_id:$software_id,
    software_client_id:$software_id,
    software_client_name:$software_name,
    software_client_description:"FinLink Financial Services demo TPP",
    software_version:"1.0",
    software_redirect_uris:[$redirect],
    software_roles:["AISP","PISP","CBPII"],
    organisation_competent_authority_claims:{
      authority_id:"DEMO-DIRECTORY",
      registration_id:"FINLINK-DEMO",
      status:"Active",
      authorisations:[
        {
          member_state:"BR",
          roles:["AISP","PISP","CBPII"]
        }
      ]
    },
    org_status:"Active",
    org_id:"finlink-demo-org",
    org_name:"FinLink",
    org_contacts:[],
    org_jwks_endpoint:$directory_jwks,
    software_jwks_endpoint:$software_jwks
  }
' > "$SSA_PAYLOAD_FILE"

"$SIGNER" sign \
  --key "$DIRECTORY_KEY" \
  --cert "$DIRECTORY_CERT" \
  --payload "$SSA_PAYLOAD_FILE" \
  > "$SSA_FILE"

chmod 600 \
  "$SSA_FILE" \
  "$SSA_PAYLOAD_FILE" \
  2>/dev/null || true

SSA_HEADER="$(jwt_header "$(cat "$SSA_FILE")")"
SSA_PAYLOAD="$(jwt_payload "$(cat "$SSA_FILE")")"

printf '%s\n' "$SSA_HEADER" |
  jq -e \
    --arg kid "$DIR_KID" \
    '.alg=="PS256" and .kid==$kid' >/dev/null ||
  die "SSA header does not prove PS256 + directory kid"

printf '%s\n' "$SSA_PAYLOAD" |
  jq -e \
    --arg iss "$DIRECTORY_ISSUER" \
    --arg sid "$SOFTWARE_ID" \
    '.iss==$iss and .software_id==$sid' >/dev/null ||
  die "SSA payload identity mismatch"

echo "Issuer     : $DIRECTORY_ISSUER"
echo "Software ID: $SOFTWARE_ID"
echo "Roles      : AISP, PISP, CBPII"
echo "Algorithm  : PS256"
echo "kid        : $DIR_KID"
echo "[OK] directory-signed SSA created"

echo
echo "============================================================"
echo "3. CREATE SIGNED REGISTRATION REQUEST"
echo "============================================================"

NOW="$(date +%s)"
EXP="$((NOW + 600))"
SSA="$(cat "$SSA_FILE")"

jq -nc \
  --arg iss "$SOFTWARE_ID" \
  --arg aud "$DCR_AUDIENCE" \
  --arg redirect "$REDIRECT_URI" \
  --arg software_id "$SOFTWARE_ID" \
  --arg software_jwks "$SOFTWARE_JWKS_INTERNAL" \
  --arg ssa "$SSA" \
  --arg jti "$(uuid)" \
  --argjson iat "$NOW" \
  --argjson exp "$EXP" '
  {
    iss:$iss,
    iat:$iat,
    exp:$exp,
    jti:$jti,
    aud:$aud,
    scope:"accounts payments fundsconfirmations",
    token_endpoint_auth_method:"tls_client_auth",
    grant_types:[
      "authorization_code",
      "client_credentials",
      "refresh_token"
    ],
    response_types:["code id_token"],
    id_token_signed_response_alg:"PS256",
    request_object_signing_alg:"PS256",
    application_type:"web",
    software_id:$software_id,
    redirect_uris:[$redirect],
    jwks_uri:$software_jwks,
    tls_client_certificate_bound_access_tokens:true,
    require_signed_request_object:true,
    token_type_extension:"JWT",
    software_statement:$ssa
  }
' > "$REG_PAYLOAD_FILE"

"$SIGNER" sign \
  --key "$TPP_KEY" \
  --cert "$TPP_CERT" \
  --payload "$REG_PAYLOAD_FILE" \
  > "$REG_REQUEST_FILE"

chmod 600 \
  "$REG_REQUEST_FILE" \
  "$REG_PAYLOAD_FILE" \
  2>/dev/null || true

REG_HEADER="$(jwt_header "$(cat "$REG_REQUEST_FILE")")"

printf '%s\n' "$REG_HEADER" |
  jq -e \
    --arg kid "$TPP_KID" \
    '.alg=="PS256" and .kid==$kid' >/dev/null ||
  die "registration request header does not prove PS256 + FinLink kid"

echo "Algorithm  : PS256"
echo "kid        : $TPP_KID"
echo "Redirect   : $REDIRECT_URI"
echo "Token auth : tls_client_auth"
echo "[OK] FinLink-signed registration request created"

echo
echo "============================================================"
echo "4. REAL FINANCIAL SERVICES DCR — MATERIALIZE CLIENT"
echo "============================================================"

DCR_CREATE_MODE="created"
CREATE_HTTP="null"

if [[ "$FRESH" == "0" && -s "$REGISTRATION_FILE" ]]; then

  DCR_CREATE_MODE="reused_existing_registration"

  echo "[RESUME] Existing DCR registration found"
  echo "[RESUME] No POST /register will be executed"

  CLIENT_ID="$(jq -er '.client_id' "$REGISTRATION_FILE")"
  CLIENT_SECRET="$(jq -er '.client_secret' "$REGISTRATION_FILE")"

  echo "Client ID: $CLIENT_ID"
  echo "Client secret: [reused from .state/dcr only]"

else

  CREATE_HTTP="$(
    curl -sS \
      --cacert "$CA" \
      --cert "$TPP_CERT" \
      --key "$TPP_KEY" \
      -o "$REGISTRATION_FILE" \
      -w '%{http_code}' \
      -X POST "$DCR_URL" \
      -H 'Content-Type: application/jwt' \
      -H 'Accept: application/json' \
      --data-binary @"$REG_REQUEST_FILE"
  )"

  echo "HTTP=$CREATE_HTTP"

  if [[ "$CREATE_HTTP" != "200" && "$CREATE_HTTP" != "201" ]]; then
    cat "$REGISTRATION_FILE" >&2 || true
    die "Financial Services DCR create failed (HTTP $CREATE_HTTP)"
  fi

  chmod 600 \
    "$REGISTRATION_FILE" \
    2>/dev/null || true

  CLIENT_ID="$(jq -er '.client_id' "$REGISTRATION_FILE")"
  CLIENT_SECRET="$(jq -er '.client_secret' "$REGISTRATION_FILE")"

  echo "Client ID: $CLIENT_ID"
  echo "Client secret: [stored only under .state/dcr]"

fi

echo

jq '
  del(.client_secret)
  | {
      client_id,
      redirect_uris,
      grant_types,
      response_types,
      token_endpoint_auth_method,
      id_token_signed_response_alg,
      request_object_signing_alg
    }
' "$REGISTRATION_FILE"

jq -e \
  --arg client "$CLIENT_ID" \
  --arg redirect "$REDIRECT_URI" '
    .client_id == $client
    and (.redirect_uris | index($redirect) != null)
    and (.grant_types | index("authorization_code") != null)
    and (.grant_types | index("client_credentials") != null)
    and (.grant_types | index("refresh_token") != null)
    and .token_endpoint_auth_method == "tls_client_auth"
    and .id_token_signed_response_alg == "PS256"
    and .request_object_signing_alg == "PS256"
  ' "$REGISTRATION_FILE" >/dev/null ||
  die "public DCR registration metadata does not match the expected client profile"

if [[ "$DCR_CREATE_MODE" == "created" ]]; then
  echo "[OK] DCR created the OAuth client and returned the expected public registration metadata"
  echo "[OK] Identity Server-only FAPI metadata was removed by the DCR response policy"
else
  echo "[OK] Existing DCR registration metadata verified"
  echo "[OK] Existing client reused without executing DCR CREATE"
fi

echo
echo "============================================================"
echo "5. PROVE CLIENT EXISTS IN IDENTITY SERVER"
echo "============================================================"

IS_APP_ID="$(resolve_is_application "$CLIENT_ID")"

curl -sS \
  --cacert "$CA" \
  -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
  "$IS_URL/api/server/v1/applications/$IS_APP_ID/inbound-protocols/oidc" \
  > "$STATE_DIR/is-oidc-after-dcr.json"

echo "IS application: $IS_APP_ID"

jq '{
  clientId,
  grantTypes,
  callbackURLs,
  publicClient,
  pkce,
  clientAuthentication,
  requestObject,
  pushAuthorizationRequest,
  isFAPIApplication
}' "$STATE_DIR/is-oidc-after-dcr.json"

[[ "$(
  jq -r '.clientId' \
    "$STATE_DIR/is-oidc-after-dcr.json"
)" == "$CLIENT_ID" ]] ||
  die "IS OAuth application clientId differs from DCR response"

echo "[OK] DCR client is a real IS OAuth application"

jq -e \
  --arg client "$CLIENT_ID" '
    .clientId == $client
    and .isFAPIApplication == true
    and .clientAuthentication.tokenEndpointAuthMethod == "tls_client_auth"
    and .accessToken.bindingType == "certificate"
    and .accessToken.validateTokenBinding == true
    and .requestObject.requestObjectSigningAlg == "PS256"
  ' "$STATE_DIR/is-oidc-after-dcr.json" >/dev/null ||
  die "effective IS OAuth application does not preserve the FAPI controls created by DCR"

echo "[OK] DCR materialized an IS FAPI application"
echo "[OK] DCR materialized tls_client_auth"
echo "[OK] DCR materialized certificate-bound access tokens"
echo "[OK] DCR materialized PS256 signed request objects"
echo "[NOTE] PAR and hybrid code id_token are normalized by the APIM access bootstrap"

echo
echo "============================================================"
echo "6. MAP DCR CLIENT TO APIM + SUBSCRIBE"
echo "============================================================"

DP_TOKEN="$(
  apim_rest_token \
    'apim:subscribe apim:app_manage' \
    'dcr-devportal'
)"

APP_NAME="FinLinkDCR-${CLIENT_ID:0:8}"
APP_ID="$(
  ensure_apim_application \
    "$DP_TOKEN" \
    "$APP_NAME"
)"

echo "APIM application: $APP_NAME ($APP_ID)"

map_dcr_client_to_apim \
  "$DP_TOKEN" \
  "$APP_ID" \
  "$CLIENT_ID" \
  "$CLIENT_SECRET"

echo "[OK] DCR-created client mapped to APIM through OOB provisioning"

echo
echo "============================================================"
echo "7. NORMALIZE SUBSCRIPTIONS + WSO2 APPLICATION RBAC"
echo "============================================================"

DEMO_APIM_APPLICATION="$APP_NAME" \
KEY_MANAGER_NAME="$KEY_MANAGER_NAME" \
./scripts/bootstrap-demo-access.sh

STATE_CLIENT="$(
  jq -er '.application.consumerKey' \
    "$ACCESS_STATE/demo-access.json"
)"

STATE_APP_ID="$(
  jq -er '.application.apimApplicationId' \
    "$ACCESS_STATE/demo-access.json"
)"

[[ "$STATE_CLIENT" == "$CLIENT_ID" ]] ||
  die "bootstrap replaced the DCR client instead of reusing it"

[[ "$STATE_APP_ID" == "$APP_ID" ]] ||
  die "bootstrap switched to a different APIM application"

curl -sS \
  --cacert "$CA" \
  -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
  "$IS_URL/api/server/v1/applications/$IS_APP_ID/inbound-protocols/oidc" \
  > "$STATE_DIR/is-oidc-after-bootstrap.json"

jq -e \
  --arg client "$CLIENT_ID" '
    .clientId == $client
    and .isFAPIApplication == true
    and .clientAuthentication.tokenEndpointAuthMethod == "tls_client_auth"
    and .accessToken.bindingType == "certificate"
    and .accessToken.validateTokenBinding == true
    and .requestObject.requestObjectSigningAlg == "PS256"
    and .pushAuthorizationRequest.requirePushAuthorizationRequest == true
    and .hybridFlow.enable == true
    and .hybridFlow.responseType == "code id_token"
    and .idToken.idTokenSignedResponseAlg == "PS256"
  ' "$STATE_DIR/is-oidc-after-bootstrap.json" >/dev/null ||
  die "post-bootstrap OAuth application does not preserve the complete FAPI runtime profile"

echo "[OK] access bootstrap normalized PAR as mandatory"
echo "[OK] access bootstrap normalized hybrid code id_token"
echo "[OK] complete post-bootstrap FAPI runtime profile verified"

DP_TOKEN="$(
  apim_rest_token \
    'apim:subscribe apim:app_manage' \
    'dcr-proof'
)"

curl -sS \
  --cacert "$CA" \
  -H "Authorization: Bearer $DP_TOKEN" \
  -G "$APIM_URL/api/am/devportal/v3/subscriptions" \
  --data-urlencode "applicationId=$APP_ID" \
  --data-urlencode 'limit=100' \
  > "$STATE_DIR/subscriptions.json"

SUBSCRIPTION_COUNT="$(
  jq '(.list // []) | length' \
    "$STATE_DIR/subscriptions.json"
)"

[[ "$SUBSCRIPTION_COUNT" -ge 3 ]] ||
  die "DCR-backed APIM application has only $SUBSCRIPTION_COUNT subscriptions"

echo "Subscriptions: $SUBSCRIPTION_COUNT"

jq -r '
  (.list // [])[]
  | "  - \(.apiInfo.name // .apiInfo.id // .apiId) / \(.status // "ready")"
' "$STATE_DIR/subscriptions.json" 2>/dev/null || true

echo "[OK] same DCR client is now the subscribed FinLink application"

echo
echo "============================================================"
echo "8. CERTIFICATE-BOUND APPLICATION TOKEN"
echo "============================================================"

issue_application_token "$CLIENT_ID"

ACCESS_TOKEN="$(
  jq -er '.access_token' \
    "$TOKEN_FILE"
)"

TOKEN_FP="$(
  printf '%s' "$ACCESS_TOKEN" |
  token_fingerprint
)"

echo "Token fingerprint: $TOKEN_FP"
echo "[OK] DCR client obtained an mTLS-bound application token"

echo
echo "============================================================"
echo "9. DCR READ REGISTRATION"
echo "============================================================"

READ_FILE="$STATE_DIR/registration-read.json"

dcr_read \
  "$CLIENT_ID" \
  "$ACCESS_TOKEN" \
  "$READ_FILE"

echo "HTTP=200"

jq '{
  client_id,
  redirect_uris,
  grant_types,
  response_types,
  token_endpoint_auth_method,
  id_token_signed_response_alg,
  request_object_signing_alg
}' "$READ_FILE"

[[ "$(
  jq -r '.client_id' \
    "$READ_FILE"
)" == "$CLIENT_ID" ]] ||
  die "DCR read returned another client"

echo "[OK] authenticated DCR read bound to the same client"

echo
echo "============================================================"
echo "10. SIGNED DCR UPDATE"
echo "============================================================"

NOW="$(date +%s)"
EXP="$((NOW + 600))"

jq \
  --arg iss "$SOFTWARE_ID" \
  --arg aud "$DCR_AUDIENCE" \
  --arg ssa "$SSA" \
  --arg jti "$(uuid)" \
  --argjson iat "$NOW" \
  --argjson exp "$EXP" '
  del(
    .client_id,
    .client_secret,
    .client_id_issued_at,
    .client_secret_expires_at,
    .registration_access_token,
    .registration_client_uri
  )
  | .iss=$iss
  | .aud=$aud
  | .iat=$iat
  | .exp=$exp
  | .jti=$jti
  | .software_statement=$ssa
' "$REG_PAYLOAD_FILE" > "$UPDATE_PAYLOAD_FILE"

"$SIGNER" sign \
  --key "$TPP_KEY" \
  --cert "$TPP_CERT" \
  --payload "$UPDATE_PAYLOAD_FILE" \
  > "$UPDATE_REQUEST_FILE"

UPDATE_HTTP="$(
  curl -sS \
    --cacert "$CA" \
    --cert "$TPP_CERT" \
    --key "$TPP_KEY" \
    -o "$STATE_DIR/registration-update-response.json" \
    -w '%{http_code}' \
    -X PUT "$DCR_URL/$CLIENT_ID" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H 'Content-Type: application/jwt' \
    -H 'Accept: application/json' \
    --data-binary @"$UPDATE_REQUEST_FILE"
)"

echo "HTTP=$UPDATE_HTTP"

if [[ "$UPDATE_HTTP" != "200" ]]; then
  cat "$STATE_DIR/registration-update-response.json" >&2 || true
  die "signed DCR update failed (HTTP $UPDATE_HTTP)"
fi

UPDATED_CLIENT="$(
  jq -r \
    '.client_id // empty' \
    "$STATE_DIR/registration-update-response.json"
)"

if [[ -n "$UPDATED_CLIENT" && "$UPDATED_CLIENT" != "$CLIENT_ID" ]]; then
  die "DCR update changed client identity"
fi

echo "[OK] signed update accepted for the existing DCR client"

echo
echo "============================================================"
echo "11. HAND OFF THE SAME CLIENT TO FINLINK"
echo "============================================================"

./demo/finlink.sh restart --no-open >/dev/null

FINLINK_CLIENT="$(
  curl -fsS \
    --cacert "$CA" \
    https://localhost:9445/healthz |
  jq -er '.client_id'
)"

echo "DCR client    : $CLIENT_ID"
echo "FinLink client: $FINLINK_CLIENT"

[[ "$FINLINK_CLIENT" == "$CLIENT_ID" ]] ||
  die "FinLink did not load the DCR-created client"

echo "[OK] consent journey will use the exact DCR-created client"

echo
echo "============================================================"
echo "12. PERSIST NON-SECRET ACT 0 PROOF"
echo "============================================================"

TPP_SUBJECT="$(
  openssl x509 \
    -in "$TPP_CERT" \
    -noout \
    -subject \
    -nameopt RFC2253 |
  sed 's/^subject=//'
)"

TPP_FP="$(
  openssl x509 \
    -in "$TPP_CERT" \
    -noout \
    -fingerprint \
    -sha256 |
  cut -d= -f2
)"

GRANTS="$(
  jq -c \
    '.grant_types // []' \
    "$REGISTRATION_FILE"
)"

ROLES="$(
  printf '%s' "$SSA_PAYLOAD" |
  jq -c '.software_roles // []'
)"

TOKEN_AUTH="$(
  jq -r \
    '.clientAuthentication.tokenEndpointAuthMethod' \
    "$STATE_DIR/is-oidc-after-bootstrap.json"
)"

CERT_BOUND="$(
  jq \
    '.accessToken.bindingType == "certificate"' \
    "$STATE_DIR/is-oidc-after-bootstrap.json"
)"

SIGNED_REQUEST="$(
  jq \
    '.requestObject.requestObjectSigningAlg == "PS256"' \
    "$STATE_DIR/is-oidc-after-bootstrap.json"
)"

jq -nc \
  --arg directory_label "Local demo regulatory-directory simulator" \
  --arg directory_issuer "$DIRECTORY_ISSUER" \
  --arg ssa_alg "PS256" \
  --arg ssa_kid "$DIR_KID" \
  --arg software_id "$SOFTWARE_ID" \
  --arg software_jwks "$SOFTWARE_JWKS_INTERNAL" \
  --arg reg_alg "PS256" \
  --arg reg_kid "$TPP_KID" \
  --arg endpoint "$DCR_URL" \
  --arg client_id "$CLIENT_ID" \
  --arg redirect "$REDIRECT_URI" \
  --arg token_auth "$TOKEN_AUTH" \
  --argjson cert_bound "$CERT_BOUND" \
  --argjson signed_request "$SIGNED_REQUEST" \
  --arg transport_subject "$TPP_SUBJECT" \
  --arg transport_fp "$TPP_FP" \
  --arg is_app_id "$IS_APP_ID" \
  --arg apim_name "$APP_NAME" \
  --arg apim_id "$APP_ID" \
  --argjson subscription_count "$SUBSCRIPTION_COUNT" \
  --argjson roles "$ROLES" \
  --argjson grants "$GRANTS" \
  --arg token_fp "$TOKEN_FP" \
  --arg create_mode "$DCR_CREATE_MODE" \
  --argjson create_http "$CREATE_HTTP" \
  --argjson read_http 200 \
  --argjson update_http "$UPDATE_HTTP" '
  {
    directory:{
      label:$directory_label,
      issuer:$directory_issuer
    },
    ssa:{
      alg:$ssa_alg,
      kid:$ssa_kid
    },
    software:{
      id:$software_id,
      roles:$roles,
      jwks_uri:$software_jwks
    },
    registration:{
      alg:$reg_alg,
      kid:$reg_kid,
      endpoint:$endpoint
    },
    client:{
      id:$client_id,
      redirect_uri:$redirect,
      grant_types:$grants,
      token_endpoint_auth_method:$token_auth,
      tls_client_certificate_bound_access_tokens:$cert_bound,
      require_signed_request_object:$signed_request,
      is_application_id:$is_app_id
    },
    transport:{
      subject:$transport_subject,
      sha256_fingerprint:$transport_fp
    },
    apim:{
      name:$apim_name,
      application_id:$apim_id,
      subscription_count:$subscription_count
    },
    proof:{
      create_mode:$create_mode,
      create_http:$create_http,
      read_http:$read_http,
      update_http:$update_http,
      application_token_fingerprint:$token_fp,
      finlink_client_match:true
    }
  }
' > "$SUMMARY_FILE"

chmod 600 \
  "$SUMMARY_FILE" \
  2>/dev/null || true

render_summary
