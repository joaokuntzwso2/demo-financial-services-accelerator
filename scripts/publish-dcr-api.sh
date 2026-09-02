#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

API_NAME="${DCR_API_NAME:-AcmeBankDynamicClientRegistrationAPI}"
API_VERSION="${DCR_API_VERSION:-v3.3.0}"
API_CONTEXT="${DCR_API_CONTEXT:-/open-banking}"
PUBLIC_PATH="${DCR_PUBLIC_PATH:-/open-banking/v3.3.0/register}"

APIM_PUBLIC="${APIM_PUBLIC:-https://localhost:${APIM_HTTPS_PORT:-9443}}"
GATEWAY_PUBLIC="${GW_PUBLIC:-https://localhost:${APIM_GATEWAY_HTTPS_PORT:-8243}}"
IS_BACKEND="${DCR_IS_BACKEND:-https://wso2is:9446/api/identity/oauth2/dcr/v1.1}"

ADMIN_USER="${APIM_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${APIM_ADMIN_PASSWORD:-admin}"
IS_ADMIN_USER="${IS_ADMIN_USER:-admin}"
IS_ADMIN_PASSWORD="${IS_ADMIN_PASSWORD:-admin}"

CA=".state/certs/ca.crt"
TPP_CERT=".state/certs/tpp.crt"
TPP_KEY=".state/certs/tpp.key"

OPENAPI="apis/dcr.yaml"
MTLS_SPEC="bootstrap/policy-specs/mtls.yaml"
DCR_REQUEST_SPEC="bootstrap/policy-specs/dcr-request.yaml"
DCR_RESPONSE_SPEC="bootstrap/policy-specs/dcr-response.yaml"

POLICY_DIR=".state/policies"
MTLS_J2="$POLICY_DIR/mtlsEnforcementPolicy.j2"
DCR_REQUEST_J2="$POLICY_DIR/dynamicClientRegistrationRequestPolicy.j2"
DCR_RESPONSE_J2="bootstrap/policy-overrides/dynamicClientRegistrationResponsePolicy.j2"

STATE=".state/dcr-api"
mkdir -p "$STATE"
chmod 700 "$STATE" 2>/dev/null || true

die() {
  echo "ERROR: $*" >&2
  exit 1
}

ok() {
  echo "[OK] $*"
}

require_file() {
  [[ -s "$1" ]] || die "missing required file: $1"
}

for command in curl jq awk; do
  command -v "$command" >/dev/null 2>&1 ||
    die "$command is required"
done

for file in \
  "$CA" \
  "$TPP_CERT" \
  "$TPP_KEY" \
  "$OPENAPI" \
  "$MTLS_SPEC" \
  "$DCR_REQUEST_SPEC" \
  "$DCR_RESPONSE_SPEC" \
  "$MTLS_J2" \
  "$DCR_REQUEST_J2" \
  "$DCR_RESPONSE_J2"
do
  require_file "$file"
done

publisher_token() {
  local reg="$STATE/publisher-client.json"
  local tok="$STATE/publisher-token.json"
  local http client secret

  http="$(
    curl -sS \
      --cacert "$CA" \
      -o "$reg" \
      -w '%{http_code}' \
      -u "${ADMIN_USER}:${ADMIN_PASSWORD}" \
      -H 'Content-Type: application/json' \
      -X POST "$APIM_PUBLIC/client-registration/v0.17/register" \
      -d "$(
        jq -nc \
          --arg owner "$ADMIN_USER" \
          --arg name "dcr-api-publisher-$(date +%s)" '
          {
            callbackUrl:"https://localhost/callback",
            clientName:$name,
            owner:$owner,
            grantType:"password refresh_token",
            saasApp:true
          }
        '
      )"
  )"

  [[ "$http" == "200" || "$http" == "201" ]] || {
    cat "$reg" >&2 || true
    die "Publisher client registration failed (HTTP $http)"
  }

  chmod 600 "$reg" 2>/dev/null || true

  client="$(jq -er '.clientId // .client_id' "$reg")"
  secret="$(jq -er '.clientSecret // .client_secret' "$reg")"

  http="$(
    curl -sS \
      --cacert "$CA" \
      -o "$tok" \
      -w '%{http_code}' \
      -u "$client:$secret" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      -X POST "$APIM_PUBLIC/oauth2/token" \
      --data-urlencode 'grant_type=password' \
      --data-urlencode "username=$ADMIN_USER" \
      --data-urlencode "password=$ADMIN_PASSWORD" \
      --data-urlencode \
        'scope=apim:api_create apim:api_manage apim:api_publish apim:api_view'
  )"

  [[ "$http" == "200" ]] || {
    cat "$tok" >&2 || true
    die "Publisher token request failed (HTTP $http)"
  }

  chmod 600 "$tok" 2>/dev/null || true
  jq -er '.access_token' "$tok"
}

TOKEN="$(publisher_token)"
AUTH=(-H "Authorization: Bearer $TOKEN")

publisher_get() {
  curl -fsS \
    --cacert "$CA" \
    "${AUTH[@]}" \
    "$1"
}

resolve_api() {
  local listing

  listing="$(
    publisher_get \
      "$APIM_PUBLIC/api/am/publisher/v4/apis?limit=100"
  )"

  printf '%s' "$listing" |
    jq -r \
      --arg name "$API_NAME" \
      --arg version "$API_VERSION" \
      --arg context "$API_CONTEXT" '
        (.list // [])[]
        | select(
            .name == $name
            and .version == $version
            and .context == $context
          )
        | .id
      ' |
    head -1
}

import_api() {
  local props response="$STATE/import.json" http

  props="$(
    jq -nc \
      --arg name "$API_NAME" \
      --arg context "$API_CONTEXT" \
      --arg version "$API_VERSION" \
      --arg backend "$IS_BACKEND" \
      --arg user "$IS_ADMIN_USER" \
      --arg pass "$IS_ADMIN_PASSWORD" '
      {
        name:$name,
        context:$context,
        version:$version,
        isDefaultVersion:false,
        enableSchemaValidation:false,
        endpointConfig:{
          endpoint_type:"http",
          production_endpoints:{url:$backend},
          sandbox_endpoints:{url:$backend},
          failOver:"false",
          endpoint_security:{
            production:{
              enabled:true,
              type:"BASIC",
              username:$user,
              password:$pass
            },
            sandbox:{
              enabled:true,
              type:"BASIC",
              username:$user,
              password:$pass
            }
          }
        },
        policies:[],
        gatewayVendor:"wso2",
        gatewayType:"wso2/synapse",
        visibility:"PUBLIC"
      }
    '
  )"

  http="$(
    curl -sS \
      --cacert "$CA" \
      -o "$response" \
      -w '%{http_code}' \
      "${AUTH[@]}" \
      -F "file=@$OPENAPI;type=application/yaml" \
      -F "additionalProperties=$props" \
      "$APIM_PUBLIC/api/am/publisher/v4/apis/import-openapi"
  )"

  if [[ "$http" == "200" || "$http" == "201" ]]; then
    jq -er '.id' "$response"
    return
  fi

  if [[ "$http" == "409" ]]; then
    local recovered
    recovered="$(resolve_api || true)"
    if [[ -n "$recovered" ]]; then
      printf '%s' "$recovered"
      return
    fi
  fi

  cat "$response" >&2 || true
  die "DCR API import failed (HTTP $http)"
}

upload_policy() {
  local api_id="$1"
  local spec="$2"
  local j2="$3"
  local name version list id out="$STATE/policy-upload.json" http

  name="$(awk '/^name:/{print $2; exit}' "$spec")"
  version="$(awk '/^version:/{print $2; exit}' "$spec")"

  [[ -n "$name" ]] || die "policy name missing in $spec"
  [[ -n "$version" ]] || die "policy version missing in $spec"

  list="$(
    publisher_get \
      "$APIM_PUBLIC/api/am/publisher/v4/apis/$api_id/operation-policies"
  )"

  id="$(
    printf '%s' "$list" |
      jq -r \
        --arg name "$name" \
        --arg version "$version" \
        '(.list // [])[]
         | select(.name==$name and .version==$version)
         | .id' |
      head -1
  )"

  if [[ -n "$id" && "$id" != "null" ]]; then
    printf '%s' "$id"
    return
  fi

  http="$(
    curl -sS \
      --cacert "$CA" \
      -o "$out" \
      -w '%{http_code}' \
      "${AUTH[@]}" \
      -F "policySpecFile=@$spec;type=application/yaml" \
      -F "synapsePolicyDefinitionFile=@$j2;type=text/plain" \
      "$APIM_PUBLIC/api/am/publisher/v4/apis/$api_id/operation-policies"
  )"

  [[ "$http" == "200" || "$http" == "201" ]] || {
    cat "$out" >&2 || true
    die "Policy upload failed for $name (HTTP $http)"
  }

  jq -er '.id' "$out"
}

configure_api() {
  local api_id="$1"
  local mtls_id="$2"
  local request_id="$3"
  local response_id="$4"
  local current out="$STATE/api-update.json" http

  current="$(
    publisher_get \
      "$APIM_PUBLIC/api/am/publisher/v4/apis/$api_id"
  )"

  printf '%s' "$current" |
    jq \
      --arg backend "$IS_BACKEND" \
      --arg user "$IS_ADMIN_USER" \
      --arg pass "$IS_ADMIN_PASSWORD" \
      --arg mtls "$mtls_id" \
      --arg request "$request_id" \
      --arg response "$response_id" '
      .context = "/open-banking"
      | .version = "v3.3.0"
      | .isDefaultVersion = false
      | .enableSchemaValidation = false
      | .policies = []
      | .transport = ["https"]
      | .endpointConfig = {
          endpoint_type:"http",
          production_endpoints:{url:$backend},
          sandbox_endpoints:{url:$backend},
          failOver:"false",
          endpoint_security:{
            production:{
              enabled:true,
              type:"BASIC",
              username:$user,
              password:$pass
            },
            sandbox:{
              enabled:true,
              type:"BASIC",
              username:$user,
              password:$pass
            }
          }
        }
      | .operations |= map(
          . as $operation
          | .operationPolicies = ((.operationPolicies // {})
            | .request = [
                {
                  policyName:"mtlsEnforcementPolicy",
                  policyVersion:"v1",
                  policyId:$mtls,
                  policyType:"api",
                  parameters:{
                    transportCertAsHeaderEnabled:false,
                    transportCertHeaderName:"x-wso2-client-certificate",
                    isClientCertificateEncoded:false
                  }
                },
                {
                  policyName:"dynamicClientRegistrationRequestPolicy",
                  policyVersion:"v2",
                  policyId:$request,
                  policyType:"api",
                  parameters:{
                    validateRequestJWT:true,
                    jwksEndpointName:"software_jwks_endpoint",
                    clientNameAttributeName:"software_client_name",
                    useSoftwareIdAsAppName:false,
                    jwksEndpointTimeout:"3000"
                  }
                }
              ]
            | .response = (
                if (
                  (($operation.verb // $operation.method // "")
                    | ascii_upcase)
                  | test("^(POST|GET|PUT)$")
                ) then
                  [
                    {
                      policyName:"dynamicClientRegistrationResponsePolicy",
                      policyVersion:"v2",
                      policyId:$response,
                      policyType:"api",
                      parameters:{}
                    }
                  ]
                else
                  []
                end
              )
          )
        )
    ' > "$STATE/desired-api.json"

  http="$(
    curl -sS \
      --cacert "$CA" \
      -o "$out" \
      -w '%{http_code}' \
      "${AUTH[@]}" \
      -H 'Content-Type: application/json' \
      -X PUT \
      "$APIM_PUBLIC/api/am/publisher/v4/apis/$api_id" \
      --data-binary @"$STATE/desired-api.json"
  )"

  [[ "$http" == "200" ]] || {
    cat "$out" >&2 || true
    die "DCR API configuration update failed (HTTP $http)"
  }

  jq -e '
    .enableSchemaValidation == false
    and (
      [.operations[]
       | .operationPolicies.request[]?
       | .policyName]
      | index("mtlsEnforcementPolicy") != null
    )
    and (
      [.operations[]
       | .operationPolicies.request[]?
       | .policyName]
      | index("dynamicClientRegistrationRequestPolicy") != null
    )
    and (
      [.operations[]
       | .operationPolicies.response[]?
       | .policyName]
      | index("dynamicClientRegistrationResponsePolicy") != null
    )
  ' "$out" >/dev/null ||
    die "Publisher response does not contain the required DCR policies"
}

deployment_target() {
  local listing api_id revisions target

  listing="$(
    publisher_get \
      "$APIM_PUBLIC/api/am/publisher/v4/apis?limit=100"
  )"

  while IFS= read -r api_id; do
    [[ -n "$api_id" ]] || continue

    revisions="$(
      publisher_get \
        "$APIM_PUBLIC/api/am/publisher/v4/apis/$api_id/revisions?query=deployed:true" \
        2>/dev/null || true
    )"

    target="$(
      printf '%s' "$revisions" |
        jq -c '
          (.list // [])[]
          | .deploymentInfo[]?
          | {
              name:.name,
              vhost:.vhost,
              displayOnDevportal:(.displayOnDevportal // true)
            }
        ' 2>/dev/null |
        head -1
    )"

    if [[ -n "$target" ]]; then
      printf '%s' "$target"
      return
    fi
  done < <(
    printf '%s' "$listing" |
      jq -r '(.list // [])[].id'
  )

  jq -nc '{
    name:"Default",
    vhost:"localhost",
    displayOnDevportal:true
  }'
}

clean_undeployed_revisions() {
  local api_id="$1"
  local revisions id

  revisions="$(
    publisher_get \
      "$APIM_PUBLIC/api/am/publisher/v4/apis/$api_id/revisions?query=deployed:false" \
      2>/dev/null || true
  )"

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue

    curl -sS \
      --cacert "$CA" \
      "${AUTH[@]}" \
      -X DELETE \
      "$APIM_PUBLIC/api/am/publisher/v4/apis/$api_id/revisions/$id" \
      >/dev/null || true
  done < <(
    printf '%s' "$revisions" |
      jq -r '(.list // [])[].id' 2>/dev/null || true
  )
}

deploy_api() {
  local api_id="$1"
  local target old_revisions old_id old_deploy
  local revision_file="$STATE/revision.json"
  local deploy_file="$STATE/deploy.json"
  local undeploy_file="$STATE/undeploy.json"
  local revision_id payload http

  clean_undeployed_revisions "$api_id"
  target="$(deployment_target)"

  old_revisions="$(
    publisher_get \
      "$APIM_PUBLIC/api/am/publisher/v4/apis/$api_id/revisions?query=deployed:true" \
      2>/dev/null || true
  )"

  old_id="$(
    printf '%s' "$old_revisions" |
      jq -r '(.list // [])[0].id // empty' 2>/dev/null || true
  )"

  old_deploy="$(
    printf '%s' "$old_revisions" |
      jq -c '
        if ((.list // []) | length) > 0 then
          [(.list[0].deploymentInfo // [])[]
           | {
               revisionUuid:.revisionUuid,
               name:.name,
               vhost:.vhost,
               displayOnDevportal:(.displayOnDevportal // true)
             }]
        else
          []
        end
      ' 2>/dev/null || printf '[]'
  )"

  http="$(
    curl -sS \
      --cacert "$CA" \
      -o "$revision_file" \
      -w '%{http_code}' \
      "${AUTH[@]}" \
      -H 'Content-Type: application/json' \
      -X POST \
      "$APIM_PUBLIC/api/am/publisher/v4/apis/$api_id/revisions" \
      -d "$(
        jq -nc \
          --arg description "FinLink real DCR Act 0 deployment" \
          '{description:$description}'
      )"
  )"

  [[ "$http" == "200" || "$http" == "201" ]] || {
    cat "$revision_file" >&2 || true
    die "DCR API revision creation failed (HTTP $http)"
  }

  revision_id="$(jq -er '.id' "$revision_file")"

  if [[ -n "$old_id" ]]; then
    http="$(
      curl -sS \
        --cacert "$CA" \
        -o "$undeploy_file" \
        -w '%{http_code}' \
        "${AUTH[@]}" \
        -H 'Content-Type: application/json' \
        -X POST \
        "$APIM_PUBLIC/api/am/publisher/v4/apis/$api_id/undeploy-revision?revisionId=$old_id" \
        -d "$old_deploy"
    )"

    [[ "$http" == "200" || "$http" == "201" ]] || {
      cat "$undeploy_file" >&2 || true
      die "Old DCR API revision undeploy failed (HTTP $http)"
    }
  fi

  payload="$(
    printf '%s' "$target" |
      jq -c \
        --arg revision "$revision_id" '
        [
          . + {revisionUuid:$revision}
        ]
      '
  )"

  http="$(
    curl -sS \
      --cacert "$CA" \
      -o "$deploy_file" \
      -w '%{http_code}' \
      "${AUTH[@]}" \
      -H 'Content-Type: application/json' \
      -X POST \
      "$APIM_PUBLIC/api/am/publisher/v4/apis/$api_id/deploy-revision?revisionId=$revision_id" \
      -d "$payload"
  )"

  [[ "$http" == "200" || "$http" == "201" ]] || {
    cat "$deploy_file" >&2 || true
    die "DCR API revision deployment failed (HTTP $http)"
  }

  if [[ -n "$old_id" ]]; then
    curl -sS \
      --cacert "$CA" \
      "${AUTH[@]}" \
      -X DELETE \
      "$APIM_PUBLIC/api/am/publisher/v4/apis/$api_id/revisions/$old_id" \
      >/dev/null || true
  fi

  printf '%s' "$revision_id"
}

wait_revision_deployed() {
  local api_id="$1"
  local revision_id="$2"
  local attempt revisions info live deployed failed success

  for attempt in $(seq 1 45); do
    revisions="$(
      publisher_get \
        "$APIM_PUBLIC/api/am/publisher/v4/apis/$api_id/revisions"
    )"

    info="$(
      printf '%s' "$revisions" |
        jq -c \
          --arg revision "$revision_id" '
          (.list // [])[]
          | select(.id==$revision)
          | (.deploymentInfo // [])[0] // {}
        '
    )"

    live="$(
      printf '%s' "$info" |
        jq -r '.liveGatewayCount // 0'
    )"
    deployed="$(
      printf '%s' "$info" |
        jq -r '.deployedGatewayCount // 0'
    )"
    failed="$(
      printf '%s' "$info" |
        jq -r '.failedGatewayCount // 0'
    )"
    success="$(
      printf '%s' "$info" |
        jq -r '.successDeployedTime // empty'
    )"

    printf \
      'deployment attempt=%02d live=%s deployed=%s failed=%s success=%s\n' \
      "$attempt" \
      "$live" \
      "$deployed" \
      "$failed" \
      "${success:-pending}"

    if [[ "$failed" -gt 0 ]]; then
      echo
      echo "Recent DCR Gateway deployment errors:"
      docker logs --since 5m wso2-ob-apim 2>&1 \
        | grep -Ei \
          'AcmeBankDynamicClientRegistrationAPI|dynamicClientRegistration|PropertyHelper|InMemoryAPIDeployer|GatewayJMSMessageListener|ERROR|Exception' \
        | tail -100 \
        || true

      die "DCR revision $revision_id failed on the Gateway"
    fi

    if [[ \
      "$live" -gt 0 \
      && "$deployed" -ge "$live" \
      && -n "$success" \
    ]]; then
      ok "revision $revision_id successfully deployed to all live Gateways"
      return 0
    fi

    sleep 2
  done

  die "timed out waiting for DCR revision $revision_id to reach the Gateway"
}

publish_api() {
  local api_id="$1"
  local api status out="$STATE/publish.json" http

  api="$(
    publisher_get \
      "$APIM_PUBLIC/api/am/publisher/v4/apis/$api_id"
  )"

  status="$(printf '%s' "$api" | jq -r '.lifeCycleStatus // empty')"

  if [[ "$status" == "PUBLISHED" ]]; then
    return
  fi

  http="$(
    curl -sS \
      --cacert "$CA" \
      -o "$out" \
      -w '%{http_code}' \
      "${AUTH[@]}" \
      -X POST \
      "$APIM_PUBLIC/api/am/publisher/v4/apis/change-lifecycle?action=Publish&apiId=$api_id"
  )"

  [[ "$http" == "200" || "$http" == "201" ]] || {
    cat "$out" >&2 || true
    die "DCR API publish failed (HTTP $http)"
  }
}

verify_gateway_surface() {
  local body="$STATE/gateway-probe.json"
  local http

  http="$(
    curl -sS \
      --cacert "$CA" \
      --cert "$TPP_CERT" \
      --key "$TPP_KEY" \
      -o "$body" \
      -w '%{http_code}' \
      -X POST "$GATEWAY_PUBLIC$PUBLIC_PATH" \
      -H 'Content-Type: application/jwt' \
      -H 'Accept: application/json' \
      --data-binary 'not-a-valid-jwt' \
      || true
  )"

  echo "Gateway probe HTTP=$http"
  head -c 1000 "$body" 2>/dev/null || true
  echo

  [[ "$http" != "000" ]] ||
    die "DCR Gateway endpoint is unreachable"

  [[ "$http" != "404" ]] ||
    die "DCR API is still not deployed at $PUBLIC_PATH"

  [[ "$http" != "401" && "$http" != "403" ]] ||
    die "DCR create endpoint incorrectly requires an OAuth token"

  ok "DCR Gateway route exists and POST is not OAuth-gated"
}

echo
echo "============================================================"
echo "DCR API — RESOLVE / IMPORT"
echo "============================================================"

API_ID="$(resolve_api || true)"

if [[ -z "$API_ID" ]]; then
  API_ID="$(import_api)"
  echo "Imported API: $API_ID"
else
  echo "Reusing API: $API_ID"
fi

printf '%s\n' "$API_ID" > "$STATE/api.id"

echo
echo "============================================================"
echo "DCR API — UPLOAD OFFICIAL MEDIATION POLICIES"
echo "============================================================"

MTLS_ID="$(
  upload_policy \
    "$API_ID" \
    "$MTLS_SPEC" \
    "$MTLS_J2"
)"

REQUEST_ID="$(
  upload_policy \
    "$API_ID" \
    "$DCR_REQUEST_SPEC" \
    "$DCR_REQUEST_J2"
)"

RESPONSE_ID="$(
  upload_policy \
    "$API_ID" \
    "$DCR_RESPONSE_SPEC" \
    "$DCR_RESPONSE_J2"
)"

echo "MTLS policy ID        : $MTLS_ID"
echo "DCR request policy ID : $REQUEST_ID"
echo "DCR response policy ID: $RESPONSE_ID"

echo
echo "============================================================"
echo "DCR API — CONFIGURE ENDPOINT + POLICIES"
echo "============================================================"

configure_api \
  "$API_ID" \
  "$MTLS_ID" \
  "$REQUEST_ID" \
  "$RESPONSE_ID"

ok "mTLS is first in every DCR request flow"
ok "DCR Request Policy is attached to every operation"
ok "DCR Response Policy is attached to POST/GET/PUT"
ok "backend uses IS DCR service with Basic endpoint authentication"
ok "schema validation is disabled for DCR"

echo
echo "============================================================"
echo "DCR API — DEPLOY REVISION"
echo "============================================================"

REVISION_ID="$(deploy_api "$API_ID")"
echo "Revision ID: $REVISION_ID"

wait_revision_deployed "$API_ID" "$REVISION_ID"

echo
echo "============================================================"
echo "DCR API — PUBLISH"
echo "============================================================"

publish_api "$API_ID"

FINAL="$(
  publisher_get \
    "$APIM_PUBLIC/api/am/publisher/v4/apis/$API_ID"
)"

printf '%s' "$FINAL" > "$STATE/final-api.json"

printf '%s' "$FINAL" |
  jq '{
    id,
    name,
    version,
    context,
    lifeCycleStatus,
    enableSchemaValidation,
    endpointConfig:{
      endpoint_type:.endpointConfig.endpoint_type,
      production_endpoints:.endpointConfig.production_endpoints
    },
    operations:[
      .operations[]
      | {
          target,
          verb,
          authType,
          requestPolicies:[
            .operationPolicies.request[]?.policyName
          ],
          responsePolicies:[
            .operationPolicies.response[]?.policyName
          ]
        }
    ]
  }'

printf '%s' "$FINAL" |
  jq -e \
    --arg name "$API_NAME" \
    --arg version "$API_VERSION" \
    --arg context "$API_CONTEXT" '
      .name == $name
      and .version == $version
      and .context == $context
      and .lifeCycleStatus == "PUBLISHED"
      and .enableSchemaValidation == false
      and (
        [.operations[]
         | select(.target=="/register")
         | select((.verb | ascii_upcase)=="POST")
         | .authType]
        | any(.=="None" or .=="NONE")
      )
      and (
        [.operations[]
         | select(.target=="/register/{ClientId}")
         | .verb]
        | map(ascii_upcase)
        | ((index("GET") != null)
           and (index("PUT") != null)
           and (index("DELETE") != null))
      )
    ' >/dev/null ||
  die "final Publisher representation does not match the DCR contract"

ok "Publisher API configuration verified"

echo
echo "============================================================"
echo "DCR API — GATEWAY SURFACE"
echo "============================================================"

verify_gateway_surface

echo
echo "============================================================"
echo "REAL DCR GATEWAY PUBLICATION PASSED"
echo "============================================================"
echo "API ID       : $API_ID"
echo "Revision ID  : $REVISION_ID"
echo "Public DCR   : $GATEWAY_PUBLIC$PUBLIC_PATH"
echo "Backend DCR  : $IS_BACKEND"
echo
echo "[OK] DCR API imported"
echo "[OK] mTLS enforced"
echo "[OK] signed-request policy attached"
echo "[OK] response policy attached"
echo "[OK] Basic endpoint authentication configured"
echo "[OK] revision deployed"
echo "[OK] API published"
echo "[OK] Gateway route reachable"
