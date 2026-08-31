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
resolve_existing_api(){
  local name=$1 version=$2 context=$3 attempts=${4:-1} delay=${5:-2}
  local i listing id code body_file candidate state_file
  local expected_versioned_context="${context}/${version}"

  body_file="/tmp/resolve-${name}.json"
  state_file="$STATE/${name}.id"

  #
  # 1. Strongest idempotency anchor: UUID persisted by a previous
  #    successful bootstrap.
  #
  # APIM can briefly reject creation because the API already exists
  # while the Publisher collection/list endpoint is still converging
  # during startup. A direct UUID lookup avoids depending on that list.
  #
  if [[ -s "$state_file" ]]; then
    candidate=$(tr -d '\r\n[:space:]' < "$state_file")

    if [[ -n "$candidate" ]]; then
      for ((i=1; i<=attempts; i++)); do
        rm -f "$body_file"

        code=$(
          curl -ksS \
            -o "$body_file" \
            -w '%{http_code}' \
            "${AUTH[@]}" \
            "$APIM_BASE/api/am/publisher/v4/apis/$candidate" \
            2>/dev/null || true
        )

        [[ -n "$code" ]] || code="000"

        if [[ "$code" =~ ^20 ]]; then
          id=$(
            jq -r \
              --arg n "$name" \
              --arg v "$version" \
              --arg c "$context" \
              --arg vc "$expected_versioned_context" \
              '
                if (
                  .name == $n
                  and .version == $v
                  and ((.context == $c) or (.context == $vc))
                )
                then .id
                else empty
                end
              ' \
              "$body_file" 2>/dev/null || true
          )

          if [[ -n "$id" ]]; then
            printf '%s' "$id"
            return 0
          fi

          # UUID exists but points at something different.
          # Never trust a stale/wrong state file blindly.
          printf \
            'WARN: persisted API UUID %s resolved but did not match %s %s %s\n' \
            "$candidate" "$name" "$version" "$context" >&2

          break
        fi

        if (( i < attempts )); then
          sleep "$delay"
        fi
      done
    fi
  fi

  #
  # 2. Normal Publisher collection lookup.
  #
  for ((i=1; i<=attempts; i++)); do
    rm -f "$body_file"

    code=$(
      curl -ksS -G \
        -o "$body_file" \
        -w '%{http_code}' \
        "${AUTH[@]}" \
        --data-urlencode "query=name:$name" \
        --data-urlencode "limit=100" \
        "$APIM_BASE/api/am/publisher/v4/apis" \
        2>/dev/null || true
    )

    [[ -n "$code" ]] || code="000"

    if [[ "$code" =~ ^20 ]]; then
      id=$(
        jq -r \
          --arg n "$name" \
          --arg v "$version" \
          --arg c "$context" \
          --arg vc "$expected_versioned_context" \
          '
            .list[]?
            | select(
                .name == $n
                and .version == $v
                and ((.context == $c) or (.context == $vc))
              )
            | .id
          ' \
          "$body_file" 2>/dev/null \
          | head -1
      )

      if [[ -n "$id" ]]; then
        printf '%s' "$id"
        return 0
      fi
    elif (( i == 1 || i == attempts )); then
      printf \
        'WARN: Publisher API lookup for %s returned HTTP %s: %s\n' \
        "$name" \
        "$code" \
        "$(cat "$body_file" 2>/dev/null || true)" >&2
    fi

    #
    # Also try the unfiltered collection. This protects against
    # transient query-index/cache behaviour.
    #
    rm -f "$body_file"

    code=$(
      curl -ksS \
        -o "$body_file" \
        -w '%{http_code}' \
        "${AUTH[@]}" \
        "$APIM_BASE/api/am/publisher/v4/apis?limit=100" \
        2>/dev/null || true
    )

    [[ -n "$code" ]] || code="000"

    if [[ "$code" =~ ^20 ]]; then
      id=$(
        jq -r \
          --arg n "$name" \
          --arg v "$version" \
          --arg c "$context" \
          --arg vc "$expected_versioned_context" \
          '
            .list[]?
            | select(
                .name == $n
                and .version == $v
                and ((.context == $c) or (.context == $vc))
              )
            | .id
          ' \
          "$body_file" 2>/dev/null \
          | head -1
      )

      if [[ -n "$id" ]]; then
        printf '%s' "$id"
        return 0
      fi
    elif (( i == 1 || i == attempts )); then
      printf \
        'WARN: Publisher full API listing for %s returned HTTP %s: %s\n' \
        "$name" \
        "$code" \
        "$(cat "$body_file" 2>/dev/null || true)" >&2
    fi

    if (( i < attempts )); then
      sleep "$delay"
    fi
  done

  return 1
}

import_api(){
  local file=$1 name=$2 context=$3 version=$4 backend=$5 regex=$6
  local id resp props code import_body

  # Fast path for normal reruns. Do not delay a genuinely fresh install.
  id=$(resolve_existing_api "$name" "$version" "$context" 1 0 || true)

  if [[ -n "$id" ]]; then
    log "Reusing existing API $name ($version, $id)"
  else
    props=$(
      jq -nc \
        --arg n "$name" \
        --arg c "$context" \
        --arg v "$version" \
        --arg u "$backend" \
        '{
          name:$n,
          context:$c,
          version:$v,
          endpointConfig:{
            endpoint_type:"default",
            production_endpoints:{url:"default"},
            sandbox_endpoints:{url:"default"},
            failOver:"false"
          },
          policies:["Unlimited"],
          gatewayVendor:"wso2",
          gatewayType:"wso2/synapse",
          visibility:"PUBLIC"
        }'
    )

    import_body="/tmp/import-${name}.json"
    rm -f "$import_body"

    if ! code=$(
      curl -ksS \
        -o "$import_body" \
        -w '%{http_code}' \
        "${AUTH[@]}" \
        -F "file=@$file;type=application/yaml" \
        -F "additionalProperties=$props" \
        "$APIM_BASE/api/am/publisher/v4/apis/import-openapi"
    ); then
      resp=$(cat "$import_body" 2>/dev/null || true)
      fatal "API import transport failure for $name: $resp"
    fi

    resp=$(cat "$import_body" 2>/dev/null || true)

    if [[ "$code" =~ ^20 ]]; then
      id=$(jq -r '.id // empty' <<<"$resp")
      log "Imported API $name ($version, $id)"

    elif [[ "$code" == "409" ]]; then
      # APIM can reach this state during startup:
      #
      #   Publisher lookup -> API temporarily not visible
      #   import-openapi    -> persistence layer sees existing context
      #
      # Treat a 409 as recoverable only if the exact expected API
      # becomes resolvable. Do NOT silently reuse an unrelated conflict.
      log "APIM reported an existing API while importing $name; resolving the exact existing API"

      id=$(resolve_existing_api "$name" "$version" "$context" 30 2 || true)

      if [[ -z "$id" ]]; then
        fatal "API import conflict for $name (HTTP 409), but the exact expected API could not be resolved: $resp"
      fi

      log "Recovered existing API $name ($version, $id) after import conflict"

    else
      fatal "API import failed for $name (HTTP $code): $resp"
    fi
  fi

  [[ -n "$id" ]] || fatal "No API id for $name"

  printf '%s\n' "$id" > "$STATE/${name}.id"

  attach_policies "$id" "$backend" "$regex"
  deploy_publish "$id" "$API_DEPLOYMENT_HASH"
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
  local mid cid did current desired
  local current_normalized desired_normalized

  mid=$(upload_api_policy "$apiid" /opt/bootstrap/mtls.yaml mtlsEnforcementPolicy.j2)
  cid=$(upload_api_policy "$apiid" /opt/bootstrap/consent.yaml consentEnforcementPolicy.j2)
  did=$(upload_api_policy "$apiid" /opt/bootstrap/dynamic.yaml dynamicEndpointPolicy.j2)

  current=$(curlj "${AUTH[@]}" "$APIM_BASE/api/am/publisher/v4/apis/$apiid")

  local basic
  basic=$(printf '%s:%s' "$WSO2_ADMIN_USER" "$WSO2_ADMIN_PASSWORD" | base64 | tr -d '\n')

  # Consent-management resources create/read the consent itself, so they
  # must not require a pre-existing consent_id.
  #
  # Business-data resources require:
  #   mTLS -> Consent Enforcement -> Dynamic Endpoint
  desired=$(
    jq \
      --arg mid "$mid" \
      --arg cid "$cid" \
      --arg did "$did" \
      --arg basic "$basic" \
      --arg is "$IS_BASE" \
      --arg backend "$backend" \
      --arg regex "$regex" '
      .endpointConfig = {
        endpoint_type:"default",
        production_endpoints:{url:"default"},
        sandbox_endpoints:{url:"default"},
        failOver:"false"
      }
      | .operations |= map(
        . as $operation
        | .operationPolicies = ((.operationPolicies // {}) |
          .request = (
            if (
              ($operation.target // "")
              | test("^/(account-access-consents|payment-consents|funds-confirmation-consents)(/|$)")
            ) then
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
          | .response = (.response // [])
          | .fault = (.fault // [])
        )
      )' <<<"$current"
  )

  #
  # Do not PUT the API on every bootstrap if the exact desired
  # configuration is already present.
  #
  current_normalized=$(jq -S -c . <<<"$current")
  desired_normalized=$(jq -S -c . <<<"$desired")

  if [[ "$current_normalized" != "$desired_normalized" ]]; then
    curlj \
      -X PUT \
      "${AUTH[@]}" \
      -H 'Content-Type: application/json' \
      -d "$desired" \
      "$APIM_BASE/api/am/publisher/v4/apis/$apiid" \
      >/dev/null \
      || fatal "Policy attachment failed for API $apiid"

    log "Updated Financial Services policies for API $apiid"
  else
    log "Financial Services policies already current for API $apiid"
  fi

  #
  # Compute a deterministic fingerprint of the gateway-relevant state.
  #
  # Do NOT hash timestamps or other mutable APIM metadata.
  #
  API_DEPLOYMENT_HASH=$(
    jq -S -c '
      {
        name: .name,
        version: .version,
        context: .context,
        endpointConfig: .endpointConfig,
        operations: (
          (.operations // [])
          | map({
              target: .target,
              verb: .verb,
              operationPolicies: (.operationPolicies // {})
            })
        )
      }
    ' <<<"$desired" \
      | sha256sum \
      | awk '{print $1}'
  )

  [[ -n "$API_DEPLOYMENT_HASH" ]] \
    || fatal "Could not calculate deployment fingerprint for API $apiid"
}


deploy_publish(){
  local apiid=$1
  local fingerprint=$2

  local revs revision_id description
  local matching_id matching_deployed
  local create_body create_code
  local deploy_body deploy_code
  local undeploy_body undeploy_code
  local delete_body delete_code
  local count candidate
  local deployed_ids old_revision
  local deployment_payload

  description="OB demo cfg:${fingerprint}"

  deployment_payload='[
    {
      "name":"Default",
      "vhost":"localhost",
      "displayOnDevportal":true
    }
  ]'

  revs=$(curlj \
    "${AUTH[@]}" \
    "$APIM_BASE/api/am/publisher/v4/apis/$apiid/revisions"
  )

  #
  # Find a revision produced from exactly the desired API configuration.
  #
  matching_id=$(
    jq -r \
      --arg d "$description" '
        .list[]?
        | select(.description == $d)
        | .id
      ' <<<"$revs" \
      | head -1
  )

  matching_deployed="false"

  if [[ -n "$matching_id" ]]; then
    if jq -e \
      --arg id "$matching_id" '
        .list[]?
        | select(.id == $id)
        | (.deploymentInfo // [])[]?
        | select(
            ((.name // "") | ascii_downcase) == "default"
          )
      ' <<<"$revs" >/dev/null 2>&1; then
      matching_deployed="true"
    fi
  fi

  #
  # Perfect idempotent case.
  #
  if [[ -n "$matching_id" && "$matching_deployed" == "true" ]]; then
    log "Gateway revision already current for API $apiid ($matching_id)"
    revision_id="$matching_id"

  else
    #
    # No matching snapshot exists yet. Create one.
    #
    if [[ -z "$matching_id" ]]; then

      #
      # APIM allows at most five revisions.
      #
      # If necessary, remove the oldest revision that is not currently
      # deployed anywhere. Never delete a deployed revision.
      #
      while true; do
        revs=$(curlj \
          "${AUTH[@]}" \
          "$APIM_BASE/api/am/publisher/v4/apis/$apiid/revisions"
        )

        count=$(jq -r '.count // (.list | length)' <<<"$revs")

        if (( count < 5 )); then
          break
        fi

        candidate=$(
          jq -r '
            [
              .list[]?
              | select(((.deploymentInfo // []) | length) == 0)
            ]
            | sort_by(.createdTime // "")
            | .[0].id // empty
          ' <<<"$revs"
        )

        if [[ -z "$candidate" ]]; then
          fatal "API $apiid has reached the 5-revision limit and no undeployed revision can safely be removed"
        fi

        log "Removing old undeployed revision $candidate for API $apiid"

        delete_body="/tmp/revision-delete-${candidate}.out"

        delete_code=$(
          curl -ksS \
            -o "$delete_body" \
            -w '%{http_code}' \
            -X DELETE \
            "${AUTH[@]}" \
            "$APIM_BASE/api/am/publisher/v4/apis/$apiid/revisions/$candidate" \
            || true
        )

        if [[ ! "$delete_code" =~ ^20 ]]; then
          fatal "Revision deletion failed for $candidate (HTTP $delete_code): $(cat "$delete_body" 2>/dev/null || true)"
        fi
      done

      create_body="/tmp/revision-create-${apiid}.out"

      create_code=$(
        curl -ksS \
          -o "$create_body" \
          -w '%{http_code}' \
          -X POST \
          "${AUTH[@]}" \
          -H 'Content-Type: application/json' \
          -d "$(jq -nc --arg d "$description" '{description:$d}')" \
          "$APIM_BASE/api/am/publisher/v4/apis/$apiid/revisions" \
          || true
      )

      if [[ ! "$create_code" =~ ^20 ]]; then
        fatal "Revision creation failed for API $apiid (HTTP $create_code): $(cat "$create_body" 2>/dev/null || true)"
      fi

      matching_id=$(
        jq -r '.id // empty' "$create_body"
      )

      [[ -n "$matching_id" ]] \
        || fatal "Revision creation returned no revision id for API $apiid"

      log "Created gateway revision $matching_id for API $apiid"
    fi

    revision_id="$matching_id"

    #
    # A Gateway environment should converge onto one revision.
    #
    # Undeploy whichever revision(s) are currently mapped to Default
    # before deploying the desired snapshot.
    #
    revs=$(curlj \
      "${AUTH[@]}" \
      "$APIM_BASE/api/am/publisher/v4/apis/$apiid/revisions"
    )

    deployed_ids=$(
      jq -r '
        .list[]?
        | (.deploymentInfo // [])[]?
        | select(
            ((.name // "") | ascii_downcase) == "default"
          )
        | .revisionUuid // empty
      ' <<<"$revs" \
      | sort -u
    )

    while IFS= read -r old_revision; do
      [[ -n "$old_revision" ]] || continue

      # It should have been caught by matching_deployed above, but
      # protect against unexpected duplicate listing state.
      if [[ "$old_revision" == "$revision_id" ]]; then
        continue
      fi

      log "Undeploying previous revision $old_revision from Default"

      undeploy_body="/tmp/revision-undeploy-${old_revision}.out"

      undeploy_code=$(
        curl -ksS \
          -o "$undeploy_body" \
          -w '%{http_code}' \
          -X POST \
          "${AUTH[@]}" \
          -H 'Content-Type: application/json' \
          -d "$deployment_payload" \
          "$APIM_BASE/api/am/publisher/v4/apis/$apiid/undeploy-revision?revisionId=$old_revision" \
          || true
      )

      if [[ ! "$undeploy_code" =~ ^20 ]]; then
        fatal "Revision undeployment failed for $old_revision (HTTP $undeploy_code): $(cat "$undeploy_body" 2>/dev/null || true)"
      fi

    done <<<"$deployed_ids"

    #
    # Deploy the desired revision.
    #
    deploy_body="/tmp/revision-deploy-${revision_id}.out"

    deploy_code=$(
      curl -ksS \
        -o "$deploy_body" \
        -w '%{http_code}' \
        -X POST \
        "${AUTH[@]}" \
        -H 'Content-Type: application/json' \
        -d "$deployment_payload" \
        "$APIM_BASE/api/am/publisher/v4/apis/$apiid/deploy-revision?revisionId=$revision_id" \
        || true
    )

    if [[ ! "$deploy_code" =~ ^20 ]]; then
      fatal "Revision deployment failed for $revision_id (HTTP $deploy_code): $(cat "$deploy_body" 2>/dev/null || true)"
    fi

    log "Deployed revision $revision_id to Default for API $apiid"
  fi

  #
  # Publishing is independent from Gateway revision deployment.
  #
  local api state

  api=$(curlj \
    "${AUTH[@]}" \
    "$APIM_BASE/api/am/publisher/v4/apis/$apiid"
  )

  state=$(jq -r '.lifeCycleStatus // empty' <<<"$api")

  if [[ "$state" != "PUBLISHED" ]]; then
    curlj \
      -X POST \
      "${AUTH[@]}" \
      "$APIM_BASE/api/am/publisher/v4/apis/change-lifecycle?action=Publish&apiId=$apiid" \
      >/dev/null \
      || fatal "Publish failed for $apiid"

    log "Published API $apiid"
  fi
}

import_api /workspace/apis/accounts.yaml AcmeBankAccountsAPI /open-banking/v3.1/aisp 3.1.0 "$BANK_BACKEND_BASE/api/fs/backend/services/accounts/accountservice" '.*account-access-consents.*'
import_api /workspace/apis/payments.yaml AcmeBankPaymentsAPI /open-banking/v3.1/pisp 3.1.0 "$BANK_BACKEND_BASE/api/fs/backend/services/payments/paymentservice" '.*payment-consents.*'
import_api /workspace/apis/cof.yaml AcmeBankConfirmationOfFundsAPI /open-banking/v3.1/cbpii 3.1.0 "$BANK_BACKEND_BASE/api/fs/backend/services/fundsConfirmation/fundsconfirmationservice" '.*funds-confirmation-consents.*'

log "Persisting bootstrap metadata"
jq -n --arg client "$CLIENT_ID" --arg created "$(date -u +%FT%TZ)" '{apimBootstrapClient:$client,completedAt:$created}' > "$STATE/result.json"

log "Bootstrap complete"
