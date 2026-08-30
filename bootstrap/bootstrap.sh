#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/bootstrap/lib.sh

: "${APIM_BASE:?}" "${IS_BASE:?}" "${BANK_BACKEND_BASE:?}" "${WSO2_ADMIN_USER:?}" "${WSO2_ADMIN_PASSWORD:?}"
STATE=/workspace/state
mkdir -p "$STATE"

log "Waiting for APIM and IS"
retry curl -ksSf "$APIM_BASE/services/Version" -o /dev/null || retry curl -ksSf "$APIM_BASE/publisher" -o /dev/null || fatal "APIM not ready"
retry curl -ksSf "$IS_BASE/oauth2/jwks" -o /dev/null || fatal "IS not ready"

log "Registering APIM bootstrap OAuth client"
DCR_PAYLOAD=$(jq -n '{callbackUrl:"www.example.com",clientName:"ob-demo-bootstrap",owner:"admin",grantType:"client_credentials password refresh_token",saasApp:true}')
DCR_RESP=$(curl -ksS -u "$WSO2_ADMIN_USER:$WSO2_ADMIN_PASSWORD" -H 'Content-Type: application/json' -d "$DCR_PAYLOAD" "$APIM_BASE/client-registration/v0.17/register")
CLIENT_ID=$(jq -r '.clientId // .client_id // empty' <<<"$DCR_RESP")
CLIENT_SECRET=$(jq -r '.clientSecret // .client_secret // empty' <<<"$DCR_RESP")
[[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]] || fatal "Could not register APIM management client: $DCR_RESP"
SCOPES='apim:api_create apim:api_manage apim:api_publish apim:api_view apim:admin apim:admin_operations apim:keymanagers_manage'
TOK_RESP=$(curl -ksS -u "$CLIENT_ID:$CLIENT_SECRET" -d grant_type=password -d "username=$WSO2_ADMIN_USER" -d "password=$WSO2_ADMIN_PASSWORD" --data-urlencode "scope=$SCOPES" "$APIM_BASE/oauth2/token")
TOKEN=$(jq -r '.access_token // empty' <<<"$TOK_RESP")
[[ -n "$TOKEN" ]] || fatal "Could not obtain APIM management token: $TOK_RESP"
AUTH=(-H "Authorization: Bearer $TOKEN")

log "Verifying APIM 4.6 ↔ IS 7.2 Key Manager integration"
KM=$(curlj "${AUTH[@]}" "$APIM_BASE/api/am/admin/v4/key-managers")
if ! jq -e '.list[]? | select((.type=="WSO2-IS-7") or (.type=="WSO2-IS"))' <<<"$KM" >/dev/null; then
  log "No IS 7.x key manager visible for the super tenant; creating one with Admin API"
  # Use Basic connector auth for the demo. Product-to-product TLS remains trusted through the shared demo CA.
  KM_BODY=$(jq -n --arg is "$IS_BASE" --arg user "$WSO2_ADMIN_USER" --arg pass "$WSO2_ADMIN_PASSWORD" '{
    name:"WSO2-IS-7",displayName:"WSO2 Identity Server 7.2",type:"WSO2-IS-7",description:"Open Banking demo authorization server",
    wellKnownEndpoint:($is+"/oauth2/token/.well-known/openid-configuration"),
    issuer:($is+"/oauth2/token"),clientRegistrationEndpoint:($is+"/api/identity/oauth2/dcr/v1.1/register"),
    introspectionEndpoint:($is+"/oauth2/introspect"),tokenEndpoint:($is+"/oauth2/token"),displayTokenEndpoint:($is+"/oauth2/token"),
    revokeEndpoint:($is+"/oauth2/revoke"),displayRevokeEndpoint:($is+"/oauth2/revoke"),userInfoEndpoint:($is+"/scim2/Me"),authorizeEndpoint:($is+"/oauth2/authorize"),
    scopeManagementEndpoint:($is+"/api/identity/oauth2/v1.0/scopes"),certificates:{type:"JWKS",value:($is+"/oauth2/jwks")},
    endpoints:[
      {name:"client_registration_endpoint",value:($is+"/api/identity/oauth2/dcr/v1.1/register")},
      {name:"introspection_endpoint",value:($is+"/oauth2/introspect")},
      {name:"token_endpoint",value:($is+"/oauth2/token")},
      {name:"revoke_endpoint",value:($is+"/oauth2/revoke")},
      {name:"userinfo_endpoint",value:($is+"/scim2/Me")},
      {name:"authorize_endpoint",value:($is+"/oauth2/authorize")},
      {name:"display_token_endpoint",value:($is+"/oauth2/token")},
      {name:"display_revoke_endpoint",value:($is+"/oauth2/revoke")}
    ],
    availableGrantTypes:["password","client_credentials","refresh_token","authorization_code","urn:ietf:params:oauth:grant-type:jwt-bearer","urn:ietf:params:oauth:grant-type:token-exchange"],
    enableOAuthAppCreation:true,enableSelfValidationJWT:true,enabled:true,tokenType:"DIRECT",
    additionalProperties:{Authentication:"BasicAuth",Username:$user,Password:$pass,api_resource_management_endpoint:($is+"/api/server/v1/api-resources"),is7_roles_endpoint:($is+"/scim2/v2/Roles"),enable_roles_creation:false,user_schema_cache_enabled:true}
  }')
  RESP=$(curl -ksS -w '\n%{http_code}' "${AUTH[@]}" -H 'Content-Type: application/json' -d "$KM_BODY" "$APIM_BASE/api/am/admin/v4/key-managers")
  CODE=${RESP##*$'\n'}; BODY=${RESP%$'\n'*}
  [[ "$CODE" =~ ^20 ]] || fatal "IS Key Manager creation failed (HTTP $CODE): $BODY"
fi

log "Importing and publishing Open Banking APIs"
import_api(){
  local file=$1 name=$2 context=$3 version=$4 backend=$5 regex=$6
  local existing id resp
  existing=$(curlj "${AUTH[@]}" "$APIM_BASE/api/am/publisher/v4/apis?query=name:$name")
  id=$(jq -r --arg n "$name" '.list[]? | select(.name==$n) | .id' <<<"$existing" | head -1)
  if [[ -z "$id" ]]; then
    local props
    props=$(jq -nc --arg n "$name" --arg c "$context" --arg v "$version" --arg u "$backend" '{name:$n,context:$c,version:$v,endpointConfig:{endpoint_type:"http",production_endpoints:{url:$u},sandbox_endpoints:{url:$u}},policies:["Unlimited"],gatewayVendor:"wso2",gatewayType:"wso2/synapse",visibility:"PUBLIC"}')
    resp=$(curl -ksS --fail-with-body "${AUTH[@]}" -F "file=@$file;type=application/yaml" -F "additionalProperties=$props" "$APIM_BASE/api/am/publisher/v4/apis/import-openapi") || fatal "API import failed for $name"
    id=$(jq -r '.id // empty' <<<"$resp")
  fi
  [[ -n "$id" ]] || fatal "No API id for $name"
  echo "$id" > "$STATE/${name}.id"
  attach_policies "$id" "$backend" "$regex"
  deploy_publish "$id"
}

find_policy_file(){
  local n=$1
  find /workspace/policies -type f -name "$n" -print -quit
}

upload_api_policy(){
  local apiid=$1 spec=$2 j2name=$3
  local j2; j2=$(find_policy_file "$j2name")
  [[ -n "$j2" ]] || fatal "Financial Services mediation policy $j2name not found in /workspace/policies"
  local list id
  list=$(curlj "${AUTH[@]}" "$APIM_BASE/api/am/publisher/v4/apis/$apiid/operation-policies")
  local pname; pname=$(awk '/^name:/{print $2;exit}' "$spec")
  id=$(jq -r --arg n "$pname" '.list[]? | select(.name==$n) | .id' <<<"$list" | head -1)
  if [[ -z "$id" ]]; then
    local out
    out=$(curl -ksS --fail-with-body "${AUTH[@]}" -F "policySpecFile=@$spec;type=application/yaml" -F "synapsePolicyDefinitionFile=@$j2;type=text/plain" "$APIM_BASE/api/am/publisher/v4/apis/$apiid/operation-policies") || fatal "Policy upload failed: $pname"
    id=$(jq -r '.id // empty' <<<"$out")
  fi
  [[ -n "$id" ]] || fatal "No operation-policy id for $pname"
  printf '%s' "$id"
}

attach_policies(){
  local apiid=$1 backend=$2 regex=$3
  local mid cid did api
  mid=$(upload_api_policy "$apiid" /opt/bootstrap/mtls.yaml mtlsEnforcementPolicy.j2)
  cid=$(upload_api_policy "$apiid" /opt/bootstrap/consent.yaml consentEnforcementPolicy.j2)
  did=$(upload_api_policy "$apiid" /opt/bootstrap/dynamic.yaml dynamicEndpointPolicy.j2)
  api=$(curlj "${AUTH[@]}" "$APIM_BASE/api/am/publisher/v4/apis/$apiid")
  local basic; basic=$(printf '%s:%s' "$WSO2_ADMIN_USER" "$WSO2_ADMIN_PASSWORD" | base64 | tr -d '\n')
  # Consent-management resources create/read the consent itself, so they
  # must not require a pre-existing consent_id. They use mTLS and are routed
  # to the Financial Services consent service in IS.
  #
  # Business-data resources require all three policies:
  # mTLS -> Consent Enforcement -> Dynamic Endpoint.
  api=$(jq --arg mid "$mid" --arg cid "$cid" --arg did "$did" --arg basic "$basic" --arg is "$IS_BASE" --arg backend "$backend" --arg regex "$regex" '
    .operations |= map(
      .operationPolicies = ((.operationPolicies // {}) |
        .request = (
          if ((.target // "") | test("^/(account-access-consents|payment-consents|funds-confirmation-consents)(/|$)")) then
            [
              {
                policyName:"mtlsEnforcementPolicy",
                policyVersion:"v1",
                policyId:$mid,
                policyType:"api",
                parameters:{
                  transportCertAsHeaderEnabled:false,
                  transportCertHeaderName:"x-wso2-client-certificate",
                  isClientCertificateEncoded:false
                }
              },
              {
                policyName:"dynamicEndpointPolicy",
                policyVersion:"v1",
                policyId:$did,
                policyType:"api",
                parameters:{
                  consentServiceRoutingRegexPattern:$regex,
                  consentServiceBasicAuthCredentials:$basic,
                  consentServiceBaseUrl:$is,
                  bankBackendBaseUrl:$backend
                }
              }
            ]
          else
            [
              {
                policyName:"mtlsEnforcementPolicy",
                policyVersion:"v1",
                policyId:$mid,
                policyType:"api",
                parameters:{
                  transportCertAsHeaderEnabled:false,
                  transportCertHeaderName:"x-wso2-client-certificate",
                  isClientCertificateEncoded:false
                }
              },
              {
                policyName:"consentEnforcementPolicy",
                policyVersion:"v1",
                policyId:$cid,
                policyType:"api",
                parameters:{
                  consentIdClaimName:"consent_id",
                  consentServiceBasicAuthCredentials:$basic,
                  consentServiceBaseUrl:$is
                }
              },
              {
                policyName:"dynamicEndpointPolicy",
                policyVersion:"v1",
                policyId:$did,
                policyType:"api",
                parameters:{
                  consentServiceRoutingRegexPattern:$regex,
                  consentServiceBasicAuthCredentials:$basic,
                  consentServiceBaseUrl:$is,
                  bankBackendBaseUrl:$backend
                }
              }
            ]
          end
        )
        | .response=(.response//[])
        | .fault=(.fault//[])
      )
    )' <<<"$api")
  curlj -X PUT "${AUTH[@]}" -H 'Content-Type: application/json' -d "$api" "$APIM_BASE/api/am/publisher/v4/apis/$apiid" >/dev/null || fatal "Policy attachment failed for API $apiid"
}

deploy_publish(){
  local apiid=$1 revs latest rev
  revs=$(curlj "${AUTH[@]}" "$APIM_BASE/api/am/publisher/v4/apis/$apiid/revisions")
  latest=$(jq -r '.list[0].id // empty' <<<"$revs")
  if [[ -z "$latest" ]]; then
    rev=$(curlj -X POST "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"description":"Automated Open Banking demo revision"}' "$APIM_BASE/api/am/publisher/v4/apis/$apiid/revisions")
    latest=$(jq -r '.id' <<<"$rev")
  fi
  # Deployment is idempotent-ish: accept 2xx; if already deployed we retain the existing deployment.
  curl -ksS -o /tmp/deploy.out -w '%{http_code}' -X POST "${AUTH[@]}" -H 'Content-Type: application/json' \
    -d '[{"name":"Default","vhost":"localhost","displayOnDevportal":true}]' \
    "$APIM_BASE/api/am/publisher/v4/apis/$apiid/deploy-revision?revisionId=$latest" > /tmp/deploy.code || true
  local c; c=$(cat /tmp/deploy.code); if [[ ! "$c" =~ ^20 && "$c" != "409" && "$c" != "400" ]]; then fatal "Revision deployment HTTP $c: $(cat /tmp/deploy.out)"; fi
  local api state; api=$(curlj "${AUTH[@]}" "$APIM_BASE/api/am/publisher/v4/apis/$apiid"); state=$(jq -r '.lifeCycleStatus // empty' <<<"$api")
  if [[ "$state" != "PUBLISHED" ]]; then
    curlj -X POST "${AUTH[@]}" "$APIM_BASE/api/am/publisher/v4/apis/change-lifecycle?action=Publish&apiId=$apiid" >/dev/null || fatal "Publish failed for $apiid"
  fi
}

import_api /workspace/apis/accounts.yaml AcmeBankAccountsAPI /open-banking/v3.1/aisp 3.1.0 "$BANK_BACKEND_BASE/api/fs/backend/services/accounts/accountservice" '.*account-access-consents.*'
import_api /workspace/apis/payments.yaml AcmeBankPaymentsAPI /open-banking/v3.1/pisp 3.1.0 "$BANK_BACKEND_BASE/api/fs/backend/services/payments/paymentservice" '.*payment-consents.*'
import_api /workspace/apis/cof.yaml AcmeBankConfirmationOfFundsAPI /open-banking/v3.1/cbpii 3.1.0 "$BANK_BACKEND_BASE/api/fs/backend/services/fundsConfirmation/fundsconfirmationservice" '.*funds-confirmation-consents.*'

log "Persisting bootstrap metadata"
jq -n --arg client "$CLIENT_ID" --arg created "$(date -u +%FT%TZ)" '{apimBootstrapClient:$client,completedAt:$created}' > "$STATE/result.json"

log "Bootstrap complete"
