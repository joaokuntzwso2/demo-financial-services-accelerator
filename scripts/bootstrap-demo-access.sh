#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-.}"
cd "$ROOT"

APIM_PUBLIC="${APIM_PUBLIC_URL:-https://localhost:9443}"
IS_PUBLIC="${IS_PUBLIC_URL:-https://localhost:9446}"
GW_PUBLIC="${GW_PUBLIC_URL:-https://localhost:8243}"

APIM_ADMIN_USER="${APIM_ADMIN_USER:-admin}"
APIM_ADMIN_PASSWORD="${APIM_ADMIN_PASSWORD:-admin}"
IS_ADMIN_USER="${IS_ADMIN_USER:-admin}"
IS_ADMIN_PASSWORD="${IS_ADMIN_PASSWORD:-admin}"

APIM_CONTAINER="${APIM_CONTAINER:-wso2-ob-apim}"
IS_CONTAINER="${IS_CONTAINER:-wso2-ob-is}"
KEY_MANAGER_NAME="${KEY_MANAGER_NAME:-FS-KEY-MANAGER}"
APP_NAME="${DEMO_APIM_APPLICATION:-OpenBankingDemoApp}"
APP_POLICY="${DEMO_APIM_THROTTLING_POLICY:-Unlimited}"

STATE_DIR=".state/demo-access"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

SCOPES_ALL="accounts payments fundsconfirmations"

ALICE_USER="${DEMO_ALICE_USER:-alice}"
ALICE_PASSWORD="${DEMO_ALICE_PASSWORD:-Alice@12345}"
BOB_USER="${DEMO_BOB_USER:-bob}"
BOB_PASSWORD="${DEMO_BOB_PASSWORD:-Bob@12345}"
CAROL_USER="${DEMO_CAROL_USER:-carol}"
CAROL_PASSWORD="${DEMO_CAROL_PASSWORD:-Carol@12345}"
DEMO_USER="${DEMO_FULL_USER:-demo}"
DEMO_PASSWORD="${DEMO_FULL_PASSWORD:-Demo@12345}"

# Progress/status output goes to stderr deliberately.
# Helper functions return IDs/tokens through stdout and are used in command
# substitutions. Status text must never contaminate those returned values.
log(){ printf '\n==> %s\n' "$*" >&2; }
ok(){ printf '[OK] %s\n' "$*" >&2; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }

for c in curl jq python3 docker keytool openssl shasum; do
  command -v "$c" >/dev/null 2>&1 || die "$c is required"
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

wait_https() {
  local url="$1" label="$2" i code
  for i in $(seq 1 90); do
    code="$(curl -ksS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
    if [[ "$code" != "000" && -n "$code" ]]; then
      ok "$label reachable (HTTP $code)"
      return 0
    fi
    sleep 2
  done
  die "$label did not become reachable: $url"
}

wait_apim_healthy() {
  local i status
  for i in $(seq 1 90); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$APIM_CONTAINER" 2>/dev/null || true)"
    if [[ "$status" == "healthy" ]]; then
      ok "API Manager is healthy"
      return 0
    fi
    sleep 2
  done
  die "API Manager did not become healthy"
}

apim_rest_token() {
  local scopes="$1" purpose="$2"
  local reg="$tmp/${purpose}-reg.json" tok="$tmp/${purpose}-token.json"
  local http cid sec

  http="$(
    curl -ksS -o "$reg" -w '%{http_code}' \
      -u "${APIM_ADMIN_USER}:${APIM_ADMIN_PASSWORD}" \
      -H 'Content-Type: application/json' \
      -X POST "$APIM_PUBLIC/client-registration/v0.17/register" \
      -d "$(jq -nc \
        --arg owner "$APIM_ADMIN_USER" \
        --arg name "fs-demo-${purpose}-$(date +%s)" \
        '{callbackUrl:"https://localhost/callback",clientName:$name,owner:$owner,grantType:"password refresh_token",saasApp:true}')"
  )"
  [[ "$http" == "200" || "$http" == "201" ]] || {
    cat "$reg" >&2 || true
    die "APIM DCR registration failed for $purpose (HTTP $http)"
  }

  cid="$(jq -er '.clientId // .client_id' "$reg")"
  sec="$(jq -er '.clientSecret // .client_secret' "$reg")"

  http="$(
    curl -ksS -o "$tok" -w '%{http_code}' \
      -u "${cid}:${sec}" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      -X POST "$APIM_PUBLIC/oauth2/token" \
      --data-urlencode 'grant_type=password' \
      --data-urlencode "username=$APIM_ADMIN_USER" \
      --data-urlencode "password=$APIM_ADMIN_PASSWORD" \
      --data-urlencode "scope=$scopes"
  )"
  [[ "$http" == "200" ]] || {
    cat "$tok" >&2 || true
    die "Could not obtain APIM REST token for scopes [$scopes] (HTTP $http)"
  }

  jq -er '.access_token' "$tok"
}

ensure_demo_ca_in_gateway_truststore() {
  local ca=".state/certs/ca.crt" alias="demo-root-ca" home truststore

  [[ -s "$ca" ]] || die "Generated demo CA not found: $ca"
  docker inspect "$APIM_CONTAINER" >/dev/null 2>&1 || die "$APIM_CONTAINER is not running"

  home="$(docker exec "$APIM_CONTAINER" sh -lc 'printf "%s" "${WSO2_SERVER_HOME:-}"' 2>/dev/null || true)"
  [[ -n "$home" ]] || home="/home/wso2carbon/wso2am-4.6.0"
  truststore="$home/repository/resources/security/client-truststore.jks"

  if docker exec "$APIM_CONTAINER" keytool \
      -list -alias "$alias" -keystore "$truststore" -storepass wso2carbon >/dev/null 2>&1; then
    ok "Gateway truststore already contains the demo Root CA"
    return
  fi

  log "Trusting generated Demo Root CA in the APIM HTTPS listener"
  docker cp "$ca" "$APIM_CONTAINER:/tmp/demo-root-ca.crt" >/dev/null
  docker exec -u root "$APIM_CONTAINER" keytool \
    -importcert -noprompt \
    -alias "$alias" \
    -file /tmp/demo-root-ca.crt \
    -keystore "$truststore" \
    -storepass wso2carbon >/dev/null
  docker exec -u root "$APIM_CONTAINER" rm -f /tmp/demo-root-ca.crt

  docker compose restart wso2apim >/dev/null
  wait_apim_healthy
  wait_https "$APIM_PUBLIC/publisher" "API Manager after truststore reload"
  ok "Demo Root CA trusted by Gateway listener"
}


verify_demo_pki_alignment() {
  local cert=".state/certs/tpp.crt"
  local home truststore
  local local_fp is_fp

  [[ -s "$cert" ]] ||
    die "Generated TPP certificate not found: $cert"

  docker inspect "$IS_CONTAINER" >/dev/null 2>&1 ||
    die "$IS_CONTAINER is not running"

  home="$(
    docker exec "$IS_CONTAINER" sh -lc \
      'printf "%s" "${WSO2_SERVER_HOME:-}"' \
      2>/dev/null || true
  )"

  [[ -n "$home" ]] ||
    home="/home/wso2carbon/wso2is-7.2.0"

  truststore="$home/repository/resources/security/client-truststore.p12"

  local_fp="$(
    openssl x509 \
      -in "$cert" \
      -outform DER \
      2>/dev/null \
      | shasum -a 256 \
      | awk '{print $1}'
  )"

  is_fp="$(
    docker exec "$IS_CONTAINER" \
      keytool \
        -exportcert \
        -alias tpp \
        -keystore "$truststore" \
        -storetype PKCS12 \
        -storepass wso2carbon \
        2>/dev/null \
      | shasum -a 256 \
      | awk '{print $1}'
  )"

  [[ -n "$local_fp" ]] ||
    die "Could not calculate local TPP certificate fingerprint"

  [[ -n "$is_fp" ]] ||
    die "Could not calculate Identity Server TPP certificate fingerprint"

  if [[ "$local_fp" != "$is_fp" ]]; then
    echo "Local TPP SHA256: $local_fp" >&2
    echo "IS TPP SHA256:    $is_fp" >&2

    die \
      "Local demo PKI does not match the running Identity Server; refusing cross-clone bootstrap"
  fi

  ok "Local demo PKI matches running Identity Server"
}

ensure_key_manager_issuer() {
  local admin_token="$1"
  local list="$tmp/km-list.json"
  local before="$tmp/km-before.json"
  local update="$tmp/km-update.json"
  local after="$tmp/km-after.json"
  local create="$tmp/km-create.json"
  local km_id issuer http field value

  # The issuer is part of the externally visible token identity.
  # Product-to-product calls must continue using Docker DNS.
  local target="${IS_PUBLIC%/}/oauth2/token"
  local internal="${IS_INTERNAL_URL:-https://wso2is:9446}"

  curl -ksS \
    -H "Authorization: Bearer $admin_token" \
    "$APIM_PUBLIC/api/am/admin/v4/key-managers?limit=100" \
    > "$list"

  km_id="$(
    jq -r --arg n "$KEY_MANAGER_NAME" \
      '(.list // [])[] | select(.name==$n) | .id' \
      "$list" \
      | head -1
  )"

  if [[ -z "$km_id" || "$km_id" == "null" ]]; then
    log "Creating Financial Services Key Manager: $KEY_MANAGER_NAME"

    http="$(
      curl -ksS \
        -o "$create" \
        -w '%{http_code}' \
        -H "Authorization: Bearer $admin_token" \
        -H 'Content-Type: application/json' \
        -X POST \
        "$APIM_PUBLIC/api/am/admin/v4/key-managers" \
        -d "$(
          jq -nc \
            --arg name "$KEY_MANAGER_NAME" \
            --arg issuer "$target" \
            --arg is "$internal" \
            --arg user "$APIM_ADMIN_USER" \
            --arg pass "$APIM_ADMIN_PASSWORD" \
            '{
              name:$name,
              displayName:"Financial Services Key Manager",
              type:"fsKeyManager",
              description:"Financial Services Accelerator Key Manager backed by WSO2 Identity Server 7.2",

              wellKnownEndpoint:($is + "/oauth2/token/.well-known/openid-configuration"),
              issuer:$issuer,

              clientRegistrationEndpoint:($is + "/api/identity/oauth2/dcr/v1.1/register"),
              introspectionEndpoint:($is + "/oauth2/introspect"),
              tokenEndpoint:($is + "/oauth2/token"),
              displayTokenEndpoint:($is + "/oauth2/token"),
              revokeEndpoint:($is + "/oauth2/revoke"),
              displayRevokeEndpoint:($is + "/oauth2/revoke"),
              userInfoEndpoint:($is + "/scim2/Me"),
              authorizeEndpoint:($is + "/oauth2/authorize"),
              scopeManagementEndpoint:($is + "/api/identity/oauth2/v1.0/scopes"),

              endpoints:[
                {
                  name:"client_registration_endpoint",
                  value:($is + "/api/identity/oauth2/dcr/v1.1/register")
                },
                {
                  name:"introspection_endpoint",
                  value:($is + "/oauth2/introspect")
                },
                {
                  name:"token_endpoint",
                  value:($is + "/oauth2/token")
                },
                {
                  name:"revoke_endpoint",
                  value:($is + "/oauth2/revoke")
                },
                {
                  name:"userinfo_endpoint",
                  value:($is + "/scim2/Me")
                },
                {
                  name:"authorize_endpoint",
                  value:($is + "/oauth2/authorize")
                },
                {
                  name:"display_token_endpoint",
                  value:($is + "/oauth2/token")
                },
                {
                  name:"display_revoke_endpoint",
                  value:($is + "/oauth2/revoke")
                }
              ],

              certificates:{
                type:"JWKS",
                value:($is + "/oauth2/jwks")
              },

              availableGrantTypes:[
                "client_credentials",
                "refresh_token",
                "authorization_code",
                "urn:ietf:params:oauth:grant-type:jwt-bearer"
              ],

              enableTokenGeneration:true,
              enableMapOAuthConsumerApps:true,
              enableOAuthAppCreation:true,
              enableSelfValidationJWT:true,
              enabled:true,
              tokenType:"DIRECT",

              additionalProperties:{
                Authentication:"BasicAuth",
                Username:$user,
                Password:$pass,
                api_resource_management_endpoint:($is + "/api/server/v1/api-resources"),
                is7_roles_endpoint:($is + "/scim2/v2/Roles"),
                enable_roles_creation:false,
                user_schema_cache_enabled:true
              }
            }'
        )"
    )"

    if [[ "$http" != "200" && "$http" != "201" ]]; then
      cat "$create" >&2 || true
      die "Could not create $KEY_MANAGER_NAME (HTTP $http)"
    fi

    km_id="$(jq -r '.id // empty' "$create")"

    # Be robust if APIM did not return the id in the create response.
    if [[ -z "$km_id" ]]; then
      curl -ksS \
        -H "Authorization: Bearer $admin_token" \
        "$APIM_PUBLIC/api/am/admin/v4/key-managers?limit=100" \
        > "$list"

      km_id="$(
        jq -r --arg n "$KEY_MANAGER_NAME" \
          '(.list // [])[] | select(.name==$n) | .id' \
          "$list" \
          | head -1
      )"
    fi

    [[ -n "$km_id" ]] ||
      die "$KEY_MANAGER_NAME was created but could not be resolved"

    ok "Created $KEY_MANAGER_NAME ($km_id)"
  fi

  curl -ksS \
    -H "Authorization: Bearer $admin_token" \
    "$APIM_PUBLIC/api/am/admin/v4/key-managers/$km_id" \
    > "$before"

  [[ "$(jq -r '.type // empty' "$before")" == "fsKeyManager" ]] ||
    die "$KEY_MANAGER_NAME exists but is not type fsKeyManager"

  issuer="$(jq -r '.issuer // empty' "$before")"

  if [[ "$issuer" != "$target" ]]; then
    log "Fixing Key Manager issuer identity"
    echo "    old: $issuer"
    echo "    new: $target"

    jq \
      --arg issuer "$target" \
      '.issuer=$issuer | del(.id)' \
      "$before" \
      > "$update"

    http="$(
      curl -ksS \
        -o "$after" \
        -w '%{http_code}' \
        -H "Authorization: Bearer $admin_token" \
        -H 'Content-Type: application/json' \
        -X PUT \
        "$APIM_PUBLIC/api/am/admin/v4/key-managers/$km_id" \
        --data-binary @"$update"
    )"

    [[ "$http" == "200" ]] || {
      cat "$after" >&2 || true
      die "Could not update Key Manager issuer (HTTP $http)"
    }
  fi

  curl -ksS \
    -H "Authorization: Bearer $admin_token" \
    "$APIM_PUBLIC/api/am/admin/v4/key-managers/$km_id" \
    > "$after"

  [[ "$(jq -r '.issuer' "$after")" == "$target" ]] ||
    die "Key Manager issuer did not persist"

  for field in \
    tokenEndpoint \
    introspectionEndpoint \
    clientRegistrationEndpoint \
    revokeEndpoint \
    authorizeEndpoint
  do
    value="$(jq -r --arg f "$field" '.[$f] // empty' "$after")"

    if [[ -n "$value" && "$value" != "$internal"/* ]]; then
      die "$field must remain Docker-internal, got: $value"
    fi
  done

  ok "$KEY_MANAGER_NAME public issuer + Docker-internal endpoint split is correct"
}

ensure_apim_application() {
  local dp_token="$1" apps="$tmp/apps.json" out="$tmp/app-create.json"
  local app_id http

  curl -ksS -H "Authorization: Bearer $dp_token" \
    "$APIM_PUBLIC/api/am/devportal/v3/applications?limit=100" > "$apps"

  app_id="$(jq -r --arg n "$APP_NAME" '(.list // [])[] | select(.name==$n) | .applicationId' "$apps" | head -1)"
  if [[ -n "$app_id" && "$app_id" != "null" ]]; then
    ok "APIM application already exists: $APP_NAME ($app_id)"
    printf '%s' "$app_id"
    return
  fi

  log "Creating APIM application: $APP_NAME"
  http="$(
    curl -ksS -o "$out" -w '%{http_code}' \
      -H "Authorization: Bearer $dp_token" \
      -H 'Content-Type: application/json' \
      -X POST "$APIM_PUBLIC/api/am/devportal/v3/applications" \
      -d "$(jq -nc --arg n "$APP_NAME" --arg p "$APP_POLICY" \
        '{name:$n,throttlingPolicy:$p,description:"Automatically bootstrapped WSO2 Financial Services demo application",tokenType:"JWT"}')"
  )"

  if [[ "$http" != "200" && "$http" != "201" ]]; then
    http="$(
      curl -ksS -o "$out" -w '%{http_code}' \
        -H "Authorization: Bearer $dp_token" \
        -H 'Content-Type: application/json' \
        -X POST "$APIM_PUBLIC/api/am/devportal/v3/applications" \
        -d "$(jq -nc --arg n "$APP_NAME" --arg p "$APP_POLICY" \
          '{name:$n,throttlingPolicy:$p,description:"Automatically bootstrapped WSO2 Financial Services demo application"}')"
    )"
  fi

  [[ "$http" == "200" || "$http" == "201" ]] || {
    cat "$out" >&2 || true
    die "Could not create APIM demo application (HTTP $http)"
  }

  app_id="$(jq -er '.applicationId' "$out")"
  ok "Created APIM application $APP_NAME ($app_id)"
  printf '%s' "$app_id"
}

discover_demo_apis() {
  local dp_token="$1"
  local apis="$tmp/apis.json"
  local selected="$STATE_DIR/apis.tsv"
  local count=0
  local http
  local i

  log "Waiting for Open Banking APIs to become visible in DevPortal"

  for i in $(seq 1 60); do
    http="$(
      curl -ksS \
        -o "$apis" \
        -w '%{http_code}' \
        -H "Authorization: Bearer $dp_token" \
        "$APIM_PUBLIC/api/am/devportal/v3/apis?limit=100" \
        2>/dev/null || true
    )"

    if [[ "$http" == "200" ]]; then
      jq -r '
        (.list // [])[]
        | select(
            ((.context // "") | test("^/open-banking/"; "i"))
            and (
              ((.context // "") | test("/aisp|/pisp|/cbpii|funds"; "i"))
              or
              ((.name // "") | test("account|payment|fund|cof"; "i"))
            )
          )
        | [.id, .name, .version, .context]
        | @tsv
      ' "$apis" \
        | awk '!seen[$1]++' \
        > "$selected"

      count="$(wc -l < "$selected" | tr -d ' ')"

      if [[ "$count" -ge 3 ]]; then
        ok "Discovered $count Open Banking APIs"
        return 0
      fi
    fi

    if (( i % 5 == 0 )); then
      echo "    Waiting for published APIs... ($count/3 visible)" >&2
    fi

    sleep 2
  done

  echo "Selected APIs:" >&2
  cat "$selected" >&2 || true

  echo "All visible APIs:" >&2
  jq -r '
    (.list // [])[]
    | [.id,.name,.version,.context]
    | @tsv
  ' "$apis" >&2 2>/dev/null || true

  die "Expected at least 3 Open Banking demo APIs, found $count after waiting"
}

ensure_subscriptions() {
  local dp_token="$1" app_id="$2"
  local id name version context out http

  log "Subscribing $APP_NAME to demo APIs"
  while IFS=$'\t' read -r id name version context; do
    out="$tmp/sub-$id.json"
    http="$(
      curl -ksS -o "$out" -w '%{http_code}' \
        -H "Authorization: Bearer $dp_token" \
        -H 'Content-Type: application/json' \
        -X POST "$APIM_PUBLIC/api/am/devportal/v3/subscriptions" \
        -d "$(jq -nc --arg api "$id" --arg app "$app_id" --arg policy "$APP_POLICY" \
          '{apiId:$api,applicationId:$app,throttlingPolicy:$policy}')"
    )"
    if [[ "$http" == "200" || "$http" == "201" || "$http" == "202" || "$http" == "409" ]]; then
      ok "Subscription ready: $name"
    else
      cat "$out" >&2 || true
      die "Subscription failed for $name (HTTP $http)"
    fi
  done < "$STATE_DIR/apis.tsv"
}

recover_existing_application_keys() {
  local dp_token="$1" app_id="$2" out="$3"
  local list="$tmp/oauth-keys.json"
  local selected="$tmp/oauth-key-selected.json"
  local detail="$tmp/oauth-key-detail.json"
  local http mapping_id consumer secret

  http="$(
    curl -ksS \
      -o "$list" \
      -w '%{http_code}' \
      -H "Authorization: Bearer $dp_token" \
      "$APIM_PUBLIC/api/am/devportal/v3/applications/$app_id/oauth-keys" \
      2>/dev/null || true
  )"

  if [[ "$http" != "200" ]]; then
    echo "WARN: OAuth key mapping lookup returned HTTP $http" >&2
    cat "$list" >&2 2>/dev/null || true
    return 1
  fi

  jq \
    --arg km "$KEY_MANAGER_NAME" '
      [
        (.list // [])[]
        | select(
            .keyType == "PRODUCTION"
            and .keyManager == $km
            and ((.consumerKey // "") != "")
          )
      ]
      | .[0] // empty
    ' "$list" > "$selected"

  mapping_id="$(jq -r '.keyMappingId // empty' "$selected" 2>/dev/null || true)"

  [[ -n "$mapping_id" ]] || return 1

  #
  # Fetch the individual mapping as well. Depending on APIM response
  # representation, the detailed resource can contain more credential
  # information than the collection entry.
  #
  http="$(
    curl -ksS \
      -o "$detail" \
      -w '%{http_code}' \
      -H "Authorization: Bearer $dp_token" \
      "$APIM_PUBLIC/api/am/devportal/v3/applications/$app_id/oauth-keys/$mapping_id" \
      2>/dev/null || true
  )"

  if [[ "$http" == "200" ]] &&
     [[ -n "$(jq -r '.consumerKey // empty' "$detail" 2>/dev/null || true)" ]]; then
    cp "$detail" "$selected"
  fi

  consumer="$(jq -r '.consumerKey // empty' "$selected")"
  secret="$(jq -r '.consumerSecret // empty' "$selected")"

  [[ -n "$consumer" ]] || return 1

  if [[ -z "$secret" ]]; then
    echo "WARN: existing OAuth key mapping $mapping_id has no retrievable consumerSecret" >&2
    return 1
  fi

  jq \
    --arg app "$app_id" \
    --arg km "$KEY_MANAGER_NAME" \
    '. + {
      applicationId:$app,
      keyManager:$km
    }' \
    "$selected" > "$out"

  chmod 600 "$out" 2>/dev/null || true

  ok "Recovered existing $KEY_MANAGER_NAME Production Keys (${consumer:0:8}...)"
  return 0
}


generate_application_keys() {
  local dp_token="$1" app_id="$2"
  local out="$STATE_DIR/application-keys.json"
  local response="$tmp/keygen.json"
  local cert=".state/certs/tpp.crt"
  local http consumer

  [[ -s "$cert" ]] ||
    die "TPP application certificate not found: $cert"

  #
  # 1. Local persisted state.
  #
  if [[ -s "$out" ]] &&
     [[ "$(jq -r '.applicationId // empty' "$out")" == "$app_id" ]] &&
     [[ "$(jq -r '.keyManager // empty' "$out")" == "$KEY_MANAGER_NAME" ]] &&
     [[ -n "$(jq -r '.consumerKey // empty' "$out")" ]] &&
     [[ -n "$(jq -r '.consumerSecret // empty' "$out")" ]]; then

    ok "Reusing persisted $KEY_MANAGER_NAME Production Keys"
    return
  fi

  #
  # 2. Recover authoritative APIM OAuth key mapping.
  #
  # The APIM/IS databases persist independently from .state, therefore
  # local state may be absent even though the application mapping already
  # exists.
  #
  if recover_existing_application_keys "$dp_token" "$app_id" "$out"; then
    return
  fi

  #
  # 3. Nothing recoverable exists. Generate the regulatory client.
  #
  log "Generating regulatory Production Keys with $KEY_MANAGER_NAME"

  http="$(
    curl -ksS \
      -o "$response" \
      -w '%{http_code}' \
      -H "Authorization: Bearer $dp_token" \
      -H 'Content-Type: application/json' \
      -X POST \
      "$APIM_PUBLIC/api/am/devportal/v3/applications/$app_id/generate-keys" \
      -d "$(
        jq -nc \
          --arg km "$KEY_MANAGER_NAME" \
          --rawfile cert "$cert" \
          '{
            keyType:"PRODUCTION",
            keyManager:$km,
            grantTypesToBeSupported:[
              "client_credentials",
              "refresh_token",
              "authorization_code"
            ],
            callbackUrl:"https://localhost/callback",
            scopes:[
              "accounts",
              "payments",
              "fundsconfirmations"
            ],
            validityTime:"3600",
            additionalProperties:{
              regulatory:"true",
              sp_certificate:$cert
            }
          }'
      )"
  )"

  if [[ "$http" == "200" || "$http" == "201" ]]; then

    jq -e '.consumerKey' "$response" >/dev/null ||
      die "Key generation response did not contain consumerKey"

    jq \
      --arg app "$app_id" \
      --arg km "$KEY_MANAGER_NAME" \
      '. + {
        applicationId:$app,
        keyManager:$km
      }' \
      "$response" > "$out"

    chmod 600 "$out" 2>/dev/null || true

    consumer="$(jq -r '.consumerKey' "$out")"
    ok "Regulatory Production Keys generated (${consumer:0:8}...)"
    return
  fi

  #
  # APIM may report that the mapping already exists when a previous
  # workflow succeeded but local state was lost. Recover it instead
  # of attempting another OAuth application creation.
  #
  if [[ "$http" == "409" ]]; then
    log "APIM reports that the Production key mapping already exists; recovering it"

    if recover_existing_application_keys "$dp_token" "$app_id" "$out"; then
      return
    fi

    echo "Key generation response:" >&2
    cat "$response" >&2 || true

    die "Production key mapping exists but could not be recovered from APIM"
  fi

  echo "Key generation response:" >&2
  cat "$response" >&2 || true
  die "Regulatory Production key generation failed (HTTP $http)"
}

resolve_is_application() {
  local consumer="$1" response="$tmp/is-apps.json"

  curl -ksS \
    -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
    -G "$IS_PUBLIC/api/server/v1/applications" \
    --data-urlencode "filter=clientId eq $consumer" \
    > "$response"

  jq -er '.applications[0].id // empty' "$response"
}

verify_fapi_application() {
  local is_app_id="$1"
  local response="$tmp/is-fapi-app.json"

  curl -ksS \
    -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
    "$IS_PUBLIC/api/server/v1/applications/$is_app_id/inbound-protocols/oidc" \
    > "$response"

  if ! jq -e '.isFAPIApplication == true' "$response" >/dev/null; then
    echo "OIDC application configuration:" >&2
    jq '{
      clientId,
      grantTypes,
      isFAPIApplication,
      clientAuthentication,
      accessToken,
      requestObject,
      idToken
    }' "$response" >&2

    die "Regulatory OAuth application is NOT FAPI enabled"
  fi

  ok "IS OAuth application is FAPI enabled"
}


ensure_is_application_certificate() {
  local is_app_id="$1"
  local before="$tmp/is-app-certificate-before.json"
  local after="$tmp/is-app-certificate-after.json"
  local patch="$tmp/is-app-certificate-patch.json"
  local cert=".state/certs/tpp.crt"
  local expected_fp actual_fp http

  [[ -s "$cert" ]] ||
    die "Generated TPP certificate not found: $cert"

  expected_fp="$(
    openssl x509 \
      -in "$cert" \
      -outform DER \
      2>/dev/null \
      | shasum -a 256 \
      | awk '{print $1}'
  )"

  [[ -n "$expected_fp" ]] ||
    die "Could not calculate expected TPP certificate fingerprint"

  curl -ksS \
    -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
    "$IS_PUBLIC/api/server/v1/applications/$is_app_id" \
    > "$before"

  actual_fp="$(
    python3 - "$before" <<'PY_CERT'
import base64
import hashlib
import json
import re
import sys

try:
    with open(sys.argv[1]) as f:
        app = json.load(f)

    value = (
        app.get("advancedConfigurations", {})
           .get("certificate", {})
           .get("value", "")
    )

    if not isinstance(value, str) or not value:
        print("")
        raise SystemExit(0)

    body = value
    body = body.replace("-----BEGIN CERTIFICATE-----", "")
    body = body.replace("-----END CERTIFICATE-----", "")
    body = re.sub(r"\s+", "", body)

    der = base64.b64decode(body, validate=True)
    print(hashlib.sha256(der).hexdigest())
except Exception:
    # Missing/malformed certificate is treated as a mismatch and repaired
    # below instead of exposing certificate contents in logs.
    print("")
PY_CERT
  )"

  if [[ "$actual_fp" == "$expected_fp" ]]; then
    ok "IS OAuth application certificate matches generated TPP certificate"
    return
  fi

  log "Normalizing IS OAuth application certificate"

  if [[ -n "$actual_fp" ]]; then
    echo "    registered SHA256: $actual_fp" >&2
  else
    echo "    registered SHA256: unavailable" >&2
  fi

  echo "    expected SHA256:   $expected_fp" >&2

  jq -n \
    --rawfile cert "$cert" \
    '{
      advancedConfigurations:{
        certificate:{
          type:"PEM",
          value:$cert
        }
      }
    }' \
    > "$patch"

  http="$(
    curl -ksS \
      -o "$after" \
      -w '%{http_code}' \
      -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
      -X PATCH \
      -H 'Content-Type: application/json' \
      "$IS_PUBLIC/api/server/v1/applications/$is_app_id" \
      --data-binary @"$patch"
  )"

  [[ "$http" == "200" ]] || {
    cat "$after" >&2 || true
    die "Could not normalize IS OAuth application certificate (HTTP $http)"
  }

  curl -ksS \
    -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
    "$IS_PUBLIC/api/server/v1/applications/$is_app_id" \
    > "$after"

  actual_fp="$(
    python3 - "$after" <<'PY_CERT'
import base64
import hashlib
import json
import re
import sys

try:
    with open(sys.argv[1]) as f:
        app = json.load(f)

    value = (
        app.get("advancedConfigurations", {})
           .get("certificate", {})
           .get("value", "")
    )

    body = value
    body = body.replace("-----BEGIN CERTIFICATE-----", "")
    body = body.replace("-----END CERTIFICATE-----", "")
    body = re.sub(r"\s+", "", body)

    der = base64.b64decode(body, validate=True)
    print(hashlib.sha256(der).hexdigest())
except Exception:
    print("")
PY_CERT
  )"

  [[ "$actual_fp" == "$expected_fp" ]] ||
    die "IS OAuth application certificate normalization did not persist"

  ok "IS OAuth application certificate matches generated TPP certificate"
}

ensure_application_role_audience() {
  local is_app_id="$1" before="$tmp/is-app-before.json" out="$tmp/is-app-patch.json"
  local audience http

  curl -ksS -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
    "$IS_PUBLIC/api/server/v1/applications/$is_app_id" > "$before"

  audience="$(jq -r '.associatedRoles.allowedAudience // empty' "$before")"
  if [[ "$audience" == "APPLICATION" ]]; then
    ok "IS OAuth application role audience is APPLICATION"
    return
  fi

  log "Setting IS OAuth application role audience to APPLICATION"
  http="$(
    curl -ksS -o "$out" -w '%{http_code}' \
      -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
      -X PATCH "$IS_PUBLIC/api/server/v1/applications/$is_app_id" \
      -H 'Content-Type: application/json' \
      -d '{"associatedRoles":{"allowedAudience":"APPLICATION"}}'
  )"
  [[ "$http" == "200" ]] || {
    cat "$out" >&2 || true
    die "Could not change IS application role audience (HTTP $http)"
  }

  audience="$(curl -ksS -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
    "$IS_PUBLIC/api/server/v1/applications/$is_app_id" |
    jq -r '.associatedRoles.allowedAudience // empty')"
  [[ "$audience" == "APPLICATION" ]] || die "IS application role audience did not become APPLICATION"
  ok "IS OAuth application role audience = APPLICATION"
}

ensure_open_banking_api_resource() {
  local scopes="$tmp/is-scopes.json" api_id="" response="$tmp/api-resource-create.json"
  local http missing_json

  curl -ksS -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
    "$IS_PUBLIC/api/server/v1/scopes" > "$scopes"

  api_id="$(
    jq -r '[.[] | select(.name=="accounts" or .name=="payments" or .name=="fundsconfirmations") | .apiID]
      | map(select(. != null and . != "")) | .[0] // empty' "$scopes"
  )"

  if [[ -z "$api_id" ]]; then
    log "Creating IS Open Banking API Resource"
    http="$(
      curl -ksS -o "$response" -w '%{http_code}' \
        -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
        -X POST "$IS_PUBLIC/api/server/v1/api-resources" \
        -H 'Content-Type: application/json' \
        -d '{
          "name":"WSO2 Open Banking Demo Resource",
          "identifier":"urn:wso2:demo:open-banking",
          "description":"API Resource for the local WSO2 Financial Services Accelerator demo",
          "requiresAuthorization":true,
          "scopes":[
            {"name":"accounts","displayName":"accounts","description":"Read bank accounts subject to consent"},
            {"name":"payments","displayName":"payments","description":"Initiate payments subject to consent"},
            {"name":"fundsconfirmations","displayName":"fundsconfirmations","description":"Confirm funds subject to consent"}
          ]
        }'
    )"
    [[ "$http" == "200" || "$http" == "201" ]] || {
      cat "$response" >&2 || true
      die "Could not create Open Banking API Resource (HTTP $http)"
    }
    api_id="$(jq -er '.id' "$response")"
  fi

  curl -ksS -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
    "$IS_PUBLIC/api/server/v1/api-resources/$api_id/scopes" > "$tmp/resource-scopes.json"

  missing_json="$(
    jq -nc --slurpfile have "$tmp/resource-scopes.json" '
      ["accounts","payments","fundsconfirmations"]
      | map(select(. as $s | ($have[0] | map(.name) | index($s)) == null))
      | map(if .=="accounts" then
          {name:.,displayName:.,description:"Read bank accounts subject to consent"}
        elif .=="payments" then
          {name:.,displayName:.,description:"Initiate payments subject to consent"}
        else
          {name:.,displayName:.,description:"Confirm funds subject to consent"}
        end)'
  )"

  if [[ "$(jq 'length' <<<"$missing_json")" -gt 0 ]]; then
    http="$(
      curl -ksS -o "$tmp/resource-scope-add.json" -w '%{http_code}' \
        -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
        -X PUT "$IS_PUBLIC/api/server/v1/api-resources/$api_id/scopes" \
        -H 'Content-Type: application/json' \
        -d "$missing_json"
    )"
    [[ "$http" == "200" || "$http" == "201" || "$http" == "204" ]] || {
      cat "$tmp/resource-scope-add.json" >&2 || true
      die "Could not add missing API Resource scopes (HTTP $http)"
    }
  fi

  ok "IS API Resource contains all Open Banking permissions"
  printf '%s' "$api_id"
}

ensure_api_authorization() {
  local is_app_id="$1" api_id="$2" auth="$tmp/authorized-apis.json"
  local existing missing out http

  curl -ksS -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
    "$IS_PUBLIC/api/server/v1/applications/$is_app_id/authorized-apis" > "$auth"

  existing="$(jq -r --arg id "$api_id" '.[] | select(.id==$id) | .id' "$auth" | head -1)"

  if [[ -z "$existing" ]]; then
    http="$(
      curl -ksS -o "$tmp/authorize-api.json" -w '%{http_code}' \
        -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
        -X POST "$IS_PUBLIC/api/server/v1/applications/$is_app_id/authorized-apis" \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg id "$api_id" \
          '{id:$id,policyIdentifier:"RBAC",scopes:["accounts","payments","fundsconfirmations"]}')"
    )"
    [[ "$http" == "200" || "$http" == "201" ]] || {
      cat "$tmp/authorize-api.json" >&2 || true
      die "Could not authorize API Resource to application (HTTP $http)"
    }
  else
    missing="$(jq -c --arg id "$api_id" '
      (.[] | select(.id==$id) | [.authorizedScopes[].name]) as $have
      | ["accounts","payments","fundsconfirmations"] - $have' "$auth")"
    if [[ "$(jq 'length' <<<"$missing")" -gt 0 ]]; then
      out="$tmp/authorize-api-patch.json"
      http="$(
        curl -ksS -o "$out" -w '%{http_code}' \
          -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
          -X PATCH "$IS_PUBLIC/api/server/v1/applications/$is_app_id/authorized-apis/$api_id" \
          -H 'Content-Type: application/json' \
          -d "$(jq -nc --argjson added "$missing" '{addedScopes:$added,removedScopes:[]}')"
      )"
      [[ "$http" == "200" ]] || {
        cat "$out" >&2 || true
        die "Could not add missing authorized scopes (HTTP $http)"
      }
    fi
  fi

  curl -ksS -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
    "$IS_PUBLIC/api/server/v1/applications/$is_app_id/authorized-apis" > "$auth"

  for s in accounts payments fundsconfirmations; do
    jq -e --arg id "$api_id" --arg s "$s" \
      '.[] | select(.id==$id) | .authorizedScopes[] | select(.name==$s)' "$auth" >/dev/null ||
      die "IS OAuth application is not authorized for scope: $s"
  done
  ok "IS OAuth application authorized for all Open Banking scopes"
}

ensure_user() {
  local username="$1" password="$2" given="$3" family="$4"
  local search="$tmp/user-${username}.json" out="$tmp/user-${username}-write.json"
  local id http

  curl -ksS -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
    -G "$IS_PUBLIC/scim2/Users" \
    --data-urlencode "filter=userName eq $username" > "$search"

  id="$(jq -r '.Resources[0].id // empty' "$search")"

  if [[ -z "$id" ]]; then
    http="$(
      curl -ksS -o "$out" -w '%{http_code}' \
        -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
        -X POST "$IS_PUBLIC/scim2/Users" \
        -H 'Content-Type: application/scim+json' \
        -d "$(jq -nc --arg u "$username" --arg p "$password" --arg g "$given" --arg f "$family" \
          '{schemas:["urn:ietf:params:scim:schemas:core:2.0:User"],userName:$u,password:$p,active:true,name:{givenName:$g,familyName:$f}}')"
    )"
    [[ "$http" == "200" || "$http" == "201" ]] || {
      cat "$out" >&2 || true
      die "Could not create IS user $username (HTTP $http)"
    }
    id="$(jq -er '.id' "$out")"
    ok "Created IS demo user: $username"
  else
    http="$(
      curl -ksS -o "$out" -w '%{http_code}' \
        -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
        -X PATCH "$IS_PUBLIC/scim2/Users/$id" \
        -H 'Content-Type: application/scim+json' \
        -d "$(jq -nc --arg p "$password" '{
          schemas:["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
          Operations:[{op:"replace",path:"password",value:$p},{op:"replace",path:"active",value:true}]
        }')"
    )"
    [[ "$http" == "200" ]] || {
      cat "$out" >&2 || true
      die "Could not normalize demo user $username (HTTP $http)"
    }
    ok "IS demo user already exists: $username"
  fi
  printf '%s' "$id"
}

ensure_role() {
  local name="$1" permission="$2" is_app_id="$3"
  shift 3
  local user_ids=("$@")
  local search="$tmp/role-$(echo "$name" | tr -cd 'A-Za-z0-9').json"
  local out="$tmp/role-write.json" role="$tmp/role-current.json"
  local role_id users_json payload http uid

  curl -ksS -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
    -G "$IS_PUBLIC/scim2/v2/Roles" \
    --data-urlencode "filter=displayName eq $name" > "$search"

  role_id="$(
    jq -r --arg app "$is_app_id" '
      (.Resources // [])[]
      | select(.audience.value==$app and (.audience.type|ascii_downcase)=="application")
      | .id' "$search" | head -1
  )"

  users_json="$(printf '%s\n' "${user_ids[@]}" | jq -R . | jq -s 'map({value:.})')"

  if [[ -z "$role_id" ]]; then
    payload="$(jq -nc --arg name "$name" --arg app "$is_app_id" --arg permission "$permission" --argjson users "$users_json" \
      '{schemas:["urn:ietf:params:scim:schemas:extension:2.0:Role"],displayName:$name,audience:{value:$app,type:"application"},users:$users,permissions:[{value:$permission,display:$permission}]}')"
    http="$(
      curl -ksS -o "$out" -w '%{http_code}' \
        -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
        -X POST "$IS_PUBLIC/scim2/v2/Roles" \
        -H 'Content-Type: application/scim+json' \
        -d "$payload"
    )"
    [[ "$http" == "200" || "$http" == "201" ]] || {
      cat "$out" >&2 || true
      die "Could not create role $name (HTTP $http)"
    }
    role_id="$(jq -er '.id' "$out")"
    ok "Created application role $name -> $permission"
  else
    payload="$(jq -nc --arg name "$name" --arg permission "$permission" --argjson users "$users_json" \
      '{displayName:$name,users:$users,groups:[],permissions:[{value:$permission,display:$permission}]}')"
    http="$(
      curl -ksS -o "$out" -w '%{http_code}' \
        -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
        -X PUT "$IS_PUBLIC/scim2/v2/Roles/$role_id" \
        -H 'Content-Type: application/scim+json' \
        -d "$payload"
    )"
    [[ "$http" == "200" ]] || {
      cat "$out" >&2 || true
      die "Could not update role $name (HTTP $http)"
    }
    ok "Application role normalized: $name"
  fi

  curl -ksS -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
    "$IS_PUBLIC/scim2/v2/Roles/$role_id" > "$role"

  jq -e --arg p "$permission" '.permissions[] | select(.value==$p)' "$role" >/dev/null ||
    die "Role $name is missing permission $permission"

  for uid in "${user_ids[@]}"; do
    jq -e --arg u "$uid" '.users[] | select(.value==$u)' "$role" >/dev/null ||
      die "Role $name does not contain expected user $uid"
  done
}

issue_application_token() {
  local consumer="$1"
  local scopes="$2"
  local outfile="$3"

  local response="$tmp/application-token.json"
  local http

  [[ -s ".state/certs/tpp.crt" ]] ||
    die "TPP transport certificate is missing"

  [[ -s ".state/certs/tpp.key" ]] ||
    die "TPP transport private key is missing"

  http="$(
    curl -ksS \
      --cert .state/certs/tpp.crt \
      --key .state/certs/tpp.key \
      -o "$response" \
      -w '%{http_code}' \
      -X POST \
      "$IS_PUBLIC/oauth2/token" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode 'grant_type=client_credentials' \
      --data-urlencode "client_id=$consumer" \
      --data-urlencode "scope=$scopes"
  )"

  [[ "$http" == "200" ]] || {
    echo "FAPI token response:" >&2
    cat "$response" >&2 || true
    die "FAPI application token request failed (HTTP $http)"
  }

  jq -e '.access_token' "$response" >/dev/null ||
    die "FAPI token response contains no access_token"

  cp "$response" "$outfile"
  chmod 600 "$outfile" 2>/dev/null || true

  ok "FAPI application token generated"
}

issue_user_token() {
  local consumer="$1" secret="$2" username="$3" password="$4" scopes="$5" outfile="$6"
  local response="$tmp/token-${username}.json" http

  http="$(
    curl -ksS -o "$response" -w '%{http_code}' \
      -u "${consumer}:${secret}" \
      -X POST "$IS_PUBLIC/oauth2/token" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode 'grant_type=password' \
      --data-urlencode "username=$username" \
      --data-urlencode "password=$password" \
      --data-urlencode "scope=$scopes"
  )"
  [[ "$http" == "200" ]] || {
    cat "$response" >&2 || true
    die "Token request failed for $username / [$scopes] (HTTP $http)"
  }
  jq -e '.access_token' "$response" >/dev/null || die "Token endpoint returned no access_token for $username"
  cp "$response" "$outfile"
  chmod 600 "$outfile" 2>/dev/null || true
}

verify_application_jwt_claims() {
  local token_file="$1"
  local consumer="$2"
  local expected_scopes="$3"

  TOKEN_FILE="$token_file" \
  EXPECTED_CONSUMER="$consumer" \
  EXPECTED_SCOPES="$expected_scopes" \
  python3 - <<'PYVERIFY'
import os
import json
import base64

data = json.load(open(os.environ["TOKEN_FILE"]))
token = data["access_token"]

parts = token.split(".")
if len(parts) != 3:
    raise SystemExit("FAPI application access token is not a JWT")

payload = parts[1] + "=" * (-len(parts[1]) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))

expected_issuer = "https://localhost:9446/oauth2/token"

if claims.get("iss") != expected_issuer:
    raise SystemExit(
        f"wrong iss claim: {claims.get('iss')!r}"
    )

expected_consumer = os.environ["EXPECTED_CONSUMER"]

actual_consumer = (
    claims.get("client_id")
    or claims.get("azp")
)

if actual_consumer != expected_consumer:
    raise SystemExit(
        f"wrong client identifier: {actual_consumer!r}"
    )

raw_scope = claims.get("scope")
actual_scopes = (
    set(raw_scope.split())
    if isinstance(raw_scope, str)
    else set(raw_scope or [])
)

expected_scopes = set(
    os.environ["EXPECTED_SCOPES"].split()
)

missing = expected_scopes - actual_scopes

if missing:
    raise SystemExit(
        f"JWT missing scopes {sorted(missing)}; "
        f"actual={raw_scope!r}"
    )

if claims.get("aut") != "APPLICATION":
    raise SystemExit(
        f"expected aut=APPLICATION, got {claims.get('aut')!r}"
    )

cnf = claims.get("cnf") or {}

if not cnf.get("x5t#S256"):
    raise SystemExit(
        f"certificate-bound cnf claim missing: {cnf!r}"
    )

print(json.dumps({
    "iss": claims.get("iss"),
    "client_id": claims.get("client_id"),
    "azp": claims.get("azp"),
    "scope": claims.get("scope"),
    "aut": claims.get("aut"),
    "cnf": claims.get("cnf")
}, indent=2))
PYVERIFY

  ok "FAPI JWT is APPLICATION + certificate-bound"
}

verify_jwt_claims() {
  local token_file="$1" consumer="$2" expected_scopes="$3" label="$4"

  TOKEN_FILE="$token_file" EXPECTED_CONSUMER="$consumer" EXPECTED_SCOPES="$expected_scopes" python3 - <<'PY'
import os, json, base64

data=json.load(open(os.environ["TOKEN_FILE"]))
token=data["access_token"]
parts=token.split(".")
if len(parts) != 3:
    raise SystemExit("access token is not a JWT")

payload=parts[1] + "=" * (-len(parts[1]) % 4)
claims=json.loads(base64.urlsafe_b64decode(payload))

issuer="https://localhost:9446/oauth2/token"
if claims.get("iss") != issuer:
    raise SystemExit(f"wrong iss claim: {claims.get('iss')!r}")

consumer=os.environ["EXPECTED_CONSUMER"]
if claims.get("client_id") != consumer:
    raise SystemExit(f"wrong client_id claim: {claims.get('client_id')!r}")

raw=claims.get("scope")
actual=set(raw.split()) if isinstance(raw,str) else set(raw or [])
expected=set(os.environ["EXPECTED_SCOPES"].split())
missing=expected-actual
if missing:
    raise SystemExit(f"JWT missing scopes {sorted(missing)}; actual scope claim={raw!r}")

if claims.get("aut") not in (None,"APPLICATION_USER"):
    raise SystemExit(f"unexpected aut claim: {claims.get('aut')!r}")

print(json.dumps({
    "iss":claims.get("iss"),
    "sub":claims.get("sub"),
    "client_id":claims.get("client_id"),
    "scope":claims.get("scope"),
    "aut":claims.get("aut")
},indent=2))
PY
  ok "$label JWT contains required issuer/client/scope claims"
}

write_state() {
  local apim_app_id="$1" is_app_id="$2" api_resource_id="$3" consumer="$4" secret="$5"
  local alice_id="$6" bob_id="$7" carol_id="$8" demo_id="$9"

  jq -n \
    --arg apimAppId "$apim_app_id" --arg isAppId "$is_app_id" --arg apiResourceId "$api_resource_id" \
    --arg appName "$APP_NAME" --arg keyManager "$KEY_MANAGER_NAME" \
    --arg consumerKey "$consumer" --arg consumerSecret "$secret" \
    --arg aliceUser "$ALICE_USER" --arg alicePassword "$ALICE_PASSWORD" --arg aliceId "$alice_id" \
    --arg bobUser "$BOB_USER" --arg bobPassword "$BOB_PASSWORD" --arg bobId "$bob_id" \
    --arg carolUser "$CAROL_USER" --arg carolPassword "$CAROL_PASSWORD" --arg carolId "$carol_id" \
    --arg demoUser "$DEMO_USER" --arg demoPassword "$DEMO_PASSWORD" --arg demoId "$demo_id" \
    '{
      application:{name:$appName,apimApplicationId:$apimAppId,isApplicationId:$isAppId,apiResourceId:$apiResourceId,keyManager:$keyManager,consumerKey:$consumerKey,consumerSecret:$consumerSecret},
      users:[
        {username:$aliceUser,password:$alicePassword,id:$aliceId,scopes:["accounts"]},
        {username:$bobUser,password:$bobPassword,id:$bobId,scopes:["payments"]},
        {username:$carolUser,password:$carolPassword,id:$carolId,scopes:["fundsconfirmations"]},
        {username:$demoUser,password:$demoPassword,id:$demoId,scopes:["accounts","payments","fundsconfirmations"]}
      ]
    }' > "$STATE_DIR/demo-access.json"
  chmod 600 "$STATE_DIR/demo-access.json" 2>/dev/null || true

  cat > "$STATE_DIR/demo-access.env" <<EOF
# Generated by scripts/bootstrap-demo-access.sh
# Demo-only credentials. This file is under .state/ and must not be committed.
export DEMO_APIM_APPLICATION='$APP_NAME'
export DEMO_CONSUMER_KEY='$consumer'
export DEMO_CONSUMER_SECRET='$secret'
export DEMO_ALICE_USER='$ALICE_USER'
export DEMO_ALICE_PASSWORD='$ALICE_PASSWORD'
export DEMO_BOB_USER='$BOB_USER'
export DEMO_BOB_PASSWORD='$BOB_PASSWORD'
export DEMO_CAROL_USER='$CAROL_USER'
export DEMO_CAROL_PASSWORD='$CAROL_PASSWORD'
export DEMO_FULL_USER='$DEMO_USER'
export DEMO_FULL_PASSWORD='$DEMO_PASSWORD'
EOF
  chmod 600 "$STATE_DIR/demo-access.env" 2>/dev/null || true
}

gateway_scope_smoke() {
  local token_file="$1" token body code
  [[ -s ".state/certs/tpp.crt" && -s ".state/certs/tpp.key" ]] || die "TPP certificate/key missing"

  token="$(jq -er '.access_token' "$token_file")"
  body="$tmp/gateway-scope-smoke.json"

  code="$(
    curl -ksS \
      --cert .state/certs/tpp.crt \
      --key .state/certs/tpp.key \
      -o "$body" \
      -w '%{http_code}' \
      "$GW_PUBLIC/open-banking/v3.1/aisp/3.1.0/accounts" \
      -H "Authorization: Bearer $token" \
      -H 'Accept: application/json' || true
  )"

  [[ "$code" != "000" && -n "$code" ]] || die "Gateway TLS/mTLS smoke test could not establish HTTP"

  if grep -Eq '"code"[[:space:]]*:[[:space:]]*"(900900|900901|900910)"' "$body"; then
    cat "$body" >&2
    die "Gateway OAuth/scope validation smoke test failed (HTTP $code)"
  fi

  ok "Gateway accepted mTLS + JWT + accounts scope (next layer HTTP $code)"
}

log "Automatic demo identity + APIM application bootstrap"
wait_https "$IS_PUBLIC/oauth2/jwks" "Identity Server"
wait_https "$APIM_PUBLIC/publisher" "API Manager"

verify_demo_pki_alignment
ensure_demo_ca_in_gateway_truststore

log "Obtaining APIM administration token"
ADMIN_TOKEN="$(apim_rest_token 'apim:admin' 'admin')"
ensure_key_manager_issuer "$ADMIN_TOKEN"

# APIM persists dynamically-created Key Managers before the corresponding
# runtime KeyManagerHolder is guaranteed to contain them. Regulatory key
# generation can therefore race immediately after first-time KM creation and
# leave a partial AM_APPLICATION_KEY_MAPPING with no consumer key.
#
# Reload APIM after the Financial Services Key Manager has been normalized so
# the runtime registry is populated from the persisted configuration before
# any application key workflow is executed.
log "Reloading API Manager after Financial Services Key Manager registration"
docker compose restart wso2apim >/dev/null

wait_https "$APIM_PUBLIC/publisher" "API Manager after Key Manager reload"

# Do not keep REST tokens across an explicit server restart.
log "Refreshing APIM administration token after Key Manager reload"
ADMIN_TOKEN="$(apim_rest_token 'apim:admin' 'admin')"

log "Obtaining Developer Portal automation token"
DP_TOKEN="$(apim_rest_token 'apim:subscribe apim:app_manage' 'devportal')"

APP_ID="$(ensure_apim_application "$DP_TOKEN")"
discover_demo_apis "$DP_TOKEN"
ensure_subscriptions "$DP_TOKEN" "$APP_ID"
generate_application_keys "$DP_TOKEN" "$APP_ID"

CONSUMER_KEY="$(jq -er '.consumerKey' "$STATE_DIR/application-keys.json")"
CONSUMER_SECRET="$(jq -er '.consumerSecret' "$STATE_DIR/application-keys.json")"

IS_APP_ID="$(resolve_is_application "$CONSUMER_KEY")"
ok "Resolved IS OAuth application: $IS_APP_ID"

verify_fapi_application "$IS_APP_ID"
ensure_is_application_certificate "$IS_APP_ID"
ensure_application_role_audience "$IS_APP_ID"
API_RESOURCE_ID="$(ensure_open_banking_api_resource)"
ensure_api_authorization "$IS_APP_ID" "$API_RESOURCE_ID"

log "Creating/normalizing demo users"
ALICE_ID="$(ensure_user "$ALICE_USER" "$ALICE_PASSWORD" "Alice" "Accounts")"
BOB_ID="$(ensure_user "$BOB_USER" "$BOB_PASSWORD" "Bob" "Payments")"
CAROL_ID="$(ensure_user "$CAROL_USER" "$CAROL_PASSWORD" "Carol" "Funds")"
DEMO_ID="$(ensure_user "$DEMO_USER" "$DEMO_PASSWORD" "Demo" "FullAccess")"

log "Creating/normalizing application-scoped RBAC roles"
ensure_role "OpenBankingAccountsUser" "accounts" "$IS_APP_ID" "$ALICE_ID" "$DEMO_ID"
ensure_role "OpenBankingPaymentsUser" "payments" "$IS_APP_ID" "$BOB_ID" "$DEMO_ID"
ensure_role "OpenBankingFundsUser" "fundsconfirmations" "$IS_APP_ID" "$CAROL_ID" "$DEMO_ID"

log "Minting and verifying FAPI application JWT"

issue_application_token \
  "$CONSUMER_KEY" \
  "accounts" \
  "$STATE_DIR/application-token.json"

verify_application_jwt_claims \
  "$STATE_DIR/application-token.json" \
  "$CONSUMER_KEY" \
  "accounts"

write_state \
  "$APP_ID" \
  "$IS_APP_ID" \
  "$API_RESOURCE_ID" \
  "$CONSUMER_KEY" \
  "$CONSUMER_SECRET" \
  "$ALICE_ID" \
  "$BOB_ID" \
  "$CAROL_ID" \
  "$DEMO_ID"

log "Gateway authentication/scope smoke test"

gateway_scope_smoke \
  "$STATE_DIR/application-token.json"

cat <<EOF

============================================================
AUTOMATIC DEMO ACCESS BOOTSTRAP PASSED
============================================================

APIM application:
  $APP_NAME

Key Manager:
  $KEY_MANAGER_NAME

Demo users:
  alice  / $ALICE_PASSWORD  -> accounts
  bob    / $BOB_PASSWORD    -> payments
  carol  / $CAROL_PASSWORD  -> fundsconfirmations
  demo   / $DEMO_PASSWORD   -> accounts payments fundsconfirmations

Runtime credentials:
  $STATE_DIR/demo-access.json
  $STATE_DIR/demo-access.env

FAPI application token generated and claim-verified:
  $STATE_DIR/application-token.json

All bootstrap identity/application/scope gates passed.

Consent-specific claims are intentionally created by the Financial Services
consent/authorization flow itself, not statically attached to users.
============================================================
EOF
