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
KEY_MANAGER_NAME="${KEY_MANAGER_NAME:-WSO2-IS-7}"
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

for c in curl jq python3 docker keytool; do
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

ensure_key_manager_issuer() {
  local admin_token="$1"
  local list="$tmp/km-list.json" before="$tmp/km-before.json" update="$tmp/km-update.json" after="$tmp/km-after.json"
  local km_id issuer http field value
  local target="https://localhost:9446/oauth2/token"

  curl -ksS -H "Authorization: Bearer $admin_token" \
    "$APIM_PUBLIC/api/am/admin/v4/key-managers?limit=100" > "$list"

  km_id="$(
    jq -er --arg n "$KEY_MANAGER_NAME" \
      '(.list // [])[] | select(.name==$n or .type==$n or .type=="WSO2-IS-7") | .id' "$list" | head -1
  )" || die "Key Manager $KEY_MANAGER_NAME was not found"

  curl -ksS -H "Authorization: Bearer $admin_token" \
    "$APIM_PUBLIC/api/am/admin/v4/key-managers/$km_id" > "$before"

  issuer="$(jq -r '.issuer // empty' "$before")"
  if [[ "$issuer" != "$target" ]]; then
    log "Fixing WSO2-IS-7 issuer identity"
    echo "    old: $issuer"
    echo "    new: $target"
    jq --arg issuer "$target" '.issuer=$issuer | del(.id)' "$before" > "$update"
    http="$(
      curl -ksS -o "$after" -w '%{http_code}' \
        -H "Authorization: Bearer $admin_token" \
        -H 'Content-Type: application/json' \
        -X PUT "$APIM_PUBLIC/api/am/admin/v4/key-managers/$km_id" \
        --data-binary @"$update"
    )"
    [[ "$http" == "200" ]] || {
      cat "$after" >&2 || true
      die "Could not update WSO2-IS-7 issuer (HTTP $http)"
    }
  fi

  curl -ksS -H "Authorization: Bearer $admin_token" \
    "$APIM_PUBLIC/api/am/admin/v4/key-managers/$km_id" > "$after"

  [[ "$(jq -r '.issuer' "$after")" == "$target" ]] || die "WSO2-IS-7 issuer did not persist"

  for field in tokenEndpoint introspectionEndpoint clientRegistrationEndpoint revokeEndpoint authorizeEndpoint; do
    value="$(jq -r --arg f "$field" '.[$f] // empty' "$after")"
    if [[ -n "$value" && "$value" != https://wso2is:9446/* ]]; then
      die "$field must remain Docker-internal, got: $value"
    fi
  done

  ok "WSO2-IS-7 public issuer + Docker-internal endpoint split is correct"
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
  local dp_token="$1" apis="$tmp/apis.json" selected="$STATE_DIR/apis.tsv" count

  curl -ksS -H "Authorization: Bearer $dp_token" \
    "$APIM_PUBLIC/api/am/devportal/v3/apis?limit=100" > "$apis"

  jq -r '
    (.list // [])[]
    | select(
        ((.context // "") | test("^/open-banking/"; "i"))
        and (
          ((.context // "") | test("/aisp|/pisp|/cbpii|funds"; "i"))
          or ((.name // "") | test("account|payment|fund|cof"; "i"))
        )
      )
    | [.id, .name, .version, .context]
    | @tsv
  ' "$apis" | awk '!seen[$1]++' > "$selected"

  count="$(wc -l < "$selected" | tr -d ' ')"
  if [[ "$count" -lt 3 ]]; then
    echo "Selected APIs:" >&2
    cat "$selected" >&2 || true
    echo "All visible APIs:" >&2
    jq -r '(.list // [])[] | [.id,.name,.version,.context] | @tsv' "$apis" >&2
    die "Expected at least 3 Open Banking demo APIs, found $count"
  fi

  ok "Discovered $count Open Banking APIs"
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

generate_application_keys() {
  local dp_token="$1" app_id="$2"
  local out="$STATE_DIR/application-keys.json" response="$tmp/keygen.json"
  local http consumer

  if [[ -s "$out" ]] &&
     [[ "$(jq -r '.applicationId // empty' "$out")" == "$app_id" ]] &&
     [[ -n "$(jq -r '.consumerKey // empty' "$out")" ]] &&
     [[ -n "$(jq -r '.consumerSecret // empty' "$out")" ]]; then
    ok "Reusing persisted demo Production Keys"
    return
  fi

  log "Generating Production Keys with $KEY_MANAGER_NAME"
  http="$(
    curl -ksS -o "$response" -w '%{http_code}' \
      -H "Authorization: Bearer $dp_token" \
      -H 'Content-Type: application/json' \
      -X POST "$APIM_PUBLIC/api/am/devportal/v3/applications/$app_id/generate-keys" \
      -d "$(jq -nc --arg km "$KEY_MANAGER_NAME" '{
        keyType:"PRODUCTION",
        keyManager:$km,
        grantTypesToBeSupported:["password","client_credentials","refresh_token","authorization_code"],
        callbackUrl:"https://localhost/callback",
        scopes:["accounts","payments","fundsconfirmations"],
        validityTime:"3600",
        additionalProperties:{}
      }')"
  )"

  [[ "$http" == "200" || "$http" == "201" ]] || {
    cat "$response" >&2 || true
    die "Production key generation failed (HTTP $http)"
  }

  jq -e '.consumerKey and .consumerSecret' "$response" >/dev/null ||
    die "Key generation response did not contain consumerKey/consumerSecret"

  jq --arg app "$app_id" --arg km "$KEY_MANAGER_NAME" \
    '. + {applicationId:$app,keyManager:$km}' "$response" > "$out"
  chmod 600 "$out" 2>/dev/null || true

  consumer="$(jq -r '.consumerKey' "$out")"
  ok "Production Keys generated (${consumer:0:8}...)"
}

resolve_is_application() {
  local consumer="$1" response="$tmp/is-apps.json"
  curl -ksS -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
    -G "$IS_PUBLIC/api/server/v1/applications" \
    --data-urlencode "filter=clientId eq $consumer" \
    --data-urlencode 'attributes=clientId,associatedRoles.allowedAudience' > "$response"

  jq -er '.applications[0].id' "$response"
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

ensure_demo_ca_in_gateway_truststore

log "Obtaining APIM administration token"
ADMIN_TOKEN="$(apim_rest_token 'apim:admin' 'admin')"
ensure_key_manager_issuer "$ADMIN_TOKEN"

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

log "Minting and verifying scoped JWTs"
issue_user_token "$CONSUMER_KEY" "$CONSUMER_SECRET" "$ALICE_USER" "$ALICE_PASSWORD" "accounts" "$STATE_DIR/alice-token.json"
verify_jwt_claims "$STATE_DIR/alice-token.json" "$CONSUMER_KEY" "accounts" "Alice"

issue_user_token "$CONSUMER_KEY" "$CONSUMER_SECRET" "$BOB_USER" "$BOB_PASSWORD" "payments" "$STATE_DIR/bob-token.json"
verify_jwt_claims "$STATE_DIR/bob-token.json" "$CONSUMER_KEY" "payments" "Bob"

issue_user_token "$CONSUMER_KEY" "$CONSUMER_SECRET" "$CAROL_USER" "$CAROL_PASSWORD" "fundsconfirmations" "$STATE_DIR/carol-token.json"
verify_jwt_claims "$STATE_DIR/carol-token.json" "$CONSUMER_KEY" "fundsconfirmations" "Carol"

issue_user_token "$CONSUMER_KEY" "$CONSUMER_SECRET" "$DEMO_USER" "$DEMO_PASSWORD" "$SCOPES_ALL" "$STATE_DIR/demo-token.json"
verify_jwt_claims "$STATE_DIR/demo-token.json" "$CONSUMER_KEY" "$SCOPES_ALL" "Demo full-access user"

write_state "$APP_ID" "$IS_APP_ID" "$API_RESOURCE_ID" "$CONSUMER_KEY" "$CONSUMER_SECRET" "$ALICE_ID" "$BOB_ID" "$CAROL_ID" "$DEMO_ID"

log "Gateway authentication/scope smoke test"
gateway_scope_smoke "$STATE_DIR/alice-token.json"

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

Tokens generated and claim-verified:
  $STATE_DIR/alice-token.json
  $STATE_DIR/bob-token.json
  $STATE_DIR/carol-token.json
  $STATE_DIR/demo-token.json

All bootstrap identity/application/scope gates passed.

Consent-specific claims are intentionally created by the Financial Services
consent/authorization flow itself, not statically attached to users.
============================================================
EOF
