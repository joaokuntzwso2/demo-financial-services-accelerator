#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

[[ -f .env ]] && set -a && source .env && set +a
[[ -f .state/demo-access/demo-access.env ]] && set -a && source .state/demo-access/demo-access.env && set +a

IS_URL="${IS_PUBLIC:-${IS_URL:-https://localhost:${IS_HTTPS_PORT:-9446}}}"
IS_ADMIN_USER="${IS_ADMIN_USER:-${WSO2_ADMIN_USER:-admin}}"
IS_ADMIN_PASSWORD="${IS_ADMIN_PASSWORD:-${WSO2_ADMIN_PASSWORD:-admin}}"

APP_NAME="FinLink Consent Manager"
RESOURCE_NAME="FinLink Consent Manager Resource"
RESOURCE_IDENTIFIER="urn:wso2:demo:consent-manager"
CALLBACK_URL="${IS_URL}/consentmgr/scp_oauth2_callback"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

die() {
  echo "ERROR: $*" >&2
  exit 1
}

ok() {
  echo "[OK] $*"
}

api() {
  curl -sS \
    --cacert .state/certs/ca.crt \
    -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
    "$@"
}

wait_for_is() {
  local i
  for i in {1..120}; do
    if curl -sSf \
      --cacert .state/certs/ca.crt \
      "${IS_URL}/oauth2/jwks" >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done
  die "WSO2 IS did not become healthy"
}

ensure_resource() {
  local list="$TMP/resources.json"
  local create="$TMP/resource-create.json"
  local scopes="$TMP/resource-scopes.json"
  local missing http api_id

  api "${IS_URL}/api/server/v1/scopes" > "$list"

  api_id="$(
    jq -r '
      [
        .[]
        | select(
            .name == "consents:read_self"
            or
            .name == "consents:read_all"
          )
        | .apiID // empty
      ]
      | map(select(. != ""))
      | group_by(.)
      | map(select(length == 2))
      | .[0][0] // empty
    ' "$list"
  )"

  if [[ -z "$api_id" ]]; then
    echo "[INFO] Creating Financial Services Consent Manager API Resource" >&2

    http="$(
      api \
        -o "$create" \
        -w '%{http_code}' \
        -X POST \
        -H 'Content-Type: application/json' \
        "${IS_URL}/api/server/v1/api-resources" \
        -d "$(jq -nc \
          --arg name "$RESOURCE_NAME" \
          --arg identifier "$RESOURCE_IDENTIFIER" \
          '{
            name:$name,
            identifier:$identifier,
            description:"API Resource used by the local Financial Services Consent Manager",
            requiresAuthorization:true,
            scopes:[
              {
                name:"consents:read_self",
                displayName:"Read own consents",
                description:"Search and manage consents granted by the signed-in customer"
              },
              {
                name:"consents:read_all",
                displayName:"Read all consents",
                description:"Search and manage consents across customers for authorized care officers"
              }
            ]
          }')"
    )"

    [[ "$http" == "200" || "$http" == "201" ]] || {
      cat "$create" >&2 || true
      die "could not create Consent Manager API Resource (HTTP $http)"
    }

    api_id="$(jq -er '.id' "$create")"
  fi

  api "${IS_URL}/api/server/v1/api-resources/$api_id/scopes" > "$scopes"

  missing="$(
    jq -nc --slurpfile have "$scopes" '
      ["consents:read_self","consents:read_all"]
      | map(select(. as $s | ($have[0] | map(.name) | index($s)) == null))
      | map(
          if . == "consents:read_self" then
            {
              name: .,
              displayName:"Read own consents",
              description:"Search and manage consents granted by the signed-in customer"
            }
          else
            {
              name: .,
              displayName:"Read all consents",
              description:"Search and manage consents across customers for authorized care officers"
            }
          end
        )
    '
  )"

  if [[ "$(jq 'length' <<<"$missing")" -gt 0 ]]; then
    http="$(
      api \
        -o "$TMP/resource-scope-add.json" \
        -w '%{http_code}' \
        -X PUT \
        -H 'Content-Type: application/json' \
        "${IS_URL}/api/server/v1/api-resources/$api_id/scopes" \
        -d "$missing"
    )"

    [[ "$http" == "200" || "$http" == "201" || "$http" == "204" ]] || {
      cat "$TMP/resource-scope-add.json" >&2 || true
      die "could not add Consent Manager API scopes (HTTP $http)"
    }
  fi

  api "${IS_URL}/api/server/v1/api-resources/$api_id/scopes" > "$scopes"

  for scope in consents:read_self consents:read_all; do
    jq -e --arg s "$scope" '.[] | select(.name==$s)' "$scopes" >/dev/null ||
      die "Consent Manager API Resource is missing $scope"
  done

  ok "Consent Manager API Resource contains consents:read_self + consents:read_all" >&2
  printf '%s' "$api_id"
}

ensure_application() {
  local apps="$TMP/apps.json"
  local create="$TMP/app-create.json"
  local current="$TMP/app.json"
  local oidc="$TMP/oidc.json"
  local oidc_out="$TMP/oidc-write.json"
  local app_id http

  api \
    -G "${IS_URL}/api/server/v1/applications" \
    --data-urlencode "filter=name eq $APP_NAME" \
    --data-urlencode "limit=100" \
    > "$apps"

  app_id="$(
    jq -r --arg name "$APP_NAME" '
      [
        .. | objects
        | select((.name? // "") == $name)
        | .id?
      ]
      | map(select(. != null and . != ""))
      | .[0] // empty
    ' "$apps"
  )"

  if [[ -z "$app_id" ]]; then
    echo "[INFO] Creating Consent Manager OAuth application" >&2

    http="$(
      api \
        -o "$create" \
        -w '%{http_code}' \
        -X POST \
        -H 'Content-Type: application/json' \
        "${IS_URL}/api/server/v1/applications" \
        -d "$(jq -nc --arg name "$APP_NAME" '{
          name:$name,
          description:"OAuth client for the WSO2 Financial Services Consent Manager demo",
          associatedRoles:{
            allowedAudience:"ORGANIZATION"
          },
          claimConfiguration:{
            dialect:"LOCAL",
            requestedClaims:[
              {
                claim:{uri:"http://wso2.org/claims/username"},
                mandatory:false
              }
            ],
            subject:{
              claim:{uri:"http://wso2.org/claims/username"},
              includeUserDomain:false,
              includeTenantDomain:false,
              useMappedLocalSubject:false,
              mappedLocalSubjectMandatory:false
            }
          },
          advancedConfigurations:{
            skipLoginConsent:false,
            skipLogoutConsent:false
          }
        }')"
    )"

    [[ "$http" == "200" || "$http" == "201" ]] || {
      cat "$create" >&2 || true
      die "could not create Consent Manager application (HTTP $http)"
    }

    app_id="$(jq -r '.id // empty' "$create" 2>/dev/null || true)"

    if [[ -z "$app_id" ]]; then
      api         -G "${IS_URL}/api/server/v1/applications"         --data-urlencode "filter=name eq $APP_NAME"         --data-urlencode "limit=100"         > "$apps"

      app_id="$(
        jq -r --arg name "$APP_NAME" '
          [
            .. | objects
            | select((.name? // "") == $name)
            | .id?
          ]
          | map(select(. != null and . != ""))
          | .[0] // empty
        ' "$apps"
      )"
    fi

    [[ -n "$app_id" ]] ||
      die "Consent Manager application was created but its application ID could not be resolved"
  fi

  http="$(
    api \
      -o "$current" \
      -w '%{http_code}' \
      -X PATCH \
      -H 'Content-Type: application/json' \
      "${IS_URL}/api/server/v1/applications/$app_id" \
      -d '{
        "associatedRoles":{"allowedAudience":"ORGANIZATION"},
        "claimConfiguration":{
          "dialect":"LOCAL",
          "requestedClaims":[
            {
              "claim":{"uri":"http://wso2.org/claims/username"},
              "mandatory":false
            }
          ],
          "subject":{
            "claim":{"uri":"http://wso2.org/claims/username"},
            "includeUserDomain":false,
            "includeTenantDomain":false,
            "useMappedLocalSubject":false,
            "mappedLocalSubjectMandatory":false
          }
        },
        "advancedConfigurations":{
          "skipLoginConsent":false,
          "skipLogoutConsent":false
        }
      }'
  )"

  [[ "$http" == "200" ]] || {
    cat "$current" >&2 || true
    die "could not normalize Consent Manager application (HTTP $http)"
  }

  local oidc_http oidc_request="$TMP/oidc-request.json"

  oidc_http="$(
    api \
      -o "$oidc" \
      -w '%{http_code}' \
      "${IS_URL}/api/server/v1/applications/$app_id/inbound-protocols/oidc"
  )"

  if [[ "$oidc_http" == "200" ]]; then
    # Preserve the server-issued clientId/clientSecret and normalize only
    # the settings required by the Consent Manager.
    jq --arg callback "$CALLBACK_URL" '
      del(.state)
      | .grantTypes = ["authorization_code","refresh_token"]
      | .callbackURLs = [$callback]
      | .allowedOrigins = []
      | .publicClient = false
      | .pkce = {
          mandatory:false,
          supportPlainTransformAlgorithm:false
        }
      | .accessToken.type = "JWT"
      | .accessToken.userAccessTokenExpiryInSeconds = 3600
      | .accessToken.applicationAccessTokenExpiryInSeconds = 3600
      | .accessToken.revokeTokensWhenIDPSessionTerminated = false
      | .accessToken.validateTokenBinding = false
      | .refreshToken.expiryInSeconds = 86400
      | .refreshToken.renewRefreshToken = true
      | .validateRequestObjectSignature = false
      | .scopeValidators = ["Role based scope validator"]
      | .clientAuthentication.tokenEndpointAuthMethod = "client_secret_basic"
      | .isFAPIApplication = false
    ' "$oidc" > "$oidc_request"

  elif [[ "$oidc_http" == "404" ]]; then
    # First-time creation: let IS generate clientId/clientSecret.
    jq -nc --arg callback "$CALLBACK_URL" '{
      grantTypes:["authorization_code","refresh_token"],
      callbackURLs:[$callback],
      allowedOrigins:[],
      publicClient:false,
      pkce:{
        mandatory:false,
        supportPlainTransformAlgorithm:false
      },
      accessToken:{
        type:"JWT",
        userAccessTokenExpiryInSeconds:3600,
        applicationAccessTokenExpiryInSeconds:3600,
        revokeTokensWhenIDPSessionTerminated:false,
        validateTokenBinding:false
      },
      refreshToken:{
        expiryInSeconds:86400,
        renewRefreshToken:true
      },
      validateRequestObjectSignature:false,
      scopeValidators:["Role based scope validator"],
      clientAuthentication:{
        tokenEndpointAuthMethod:"client_secret_basic"
      },
      isFAPIApplication:false
    }' > "$oidc_request"

  else
    cat "$oidc" >&2 || true
    die "could not read current Consent Manager OIDC configuration (HTTP $oidc_http)"
  fi

  http="$(
    api \
      -o "$oidc_out" \
      -w '%{http_code}' \
      -X PUT \
      -H 'Content-Type: application/json' \
      "${IS_URL}/api/server/v1/applications/$app_id/inbound-protocols/oidc" \
      --data-binary @"$oidc_request"
  )"

  [[ "$http" == "200" || "$http" == "201" ]] || {
    cat "$oidc_out" >&2 || true
    die "could not create/update Consent Manager OIDC configuration (HTTP $http)"
  }

  api "${IS_URL}/api/server/v1/applications/$app_id/inbound-protocols/oidc" > "$oidc"

  local client_id client_secret
  client_id="$(jq -r '.clientId // empty' "$oidc")"
  client_secret="$(jq -r '.clientSecret // empty' "$oidc")"

  [[ -n "$client_id" ]] ||
    die "Consent Manager OIDC client ID was not returned"

  if [[ -z "$client_secret" || "$client_secret" == "********" ]]; then
    http="$(
      api \
        -o "$TMP/secret.json" \
        -w '%{http_code}' \
        -X POST \
        "${IS_URL}/api/server/v1/applications/$app_id/inbound-protocols/oidc/regenerate-secret"
    )"

    [[ "$http" == "200" ]] || {
      cat "$TMP/secret.json" >&2 || true
      die "could not obtain Consent Manager client secret (HTTP $http)"
    }

    client_secret="$(jq -r '.clientSecret // .secret // empty' "$TMP/secret.json")"
  fi

  [[ -n "$client_secret" && "$client_secret" != "********" ]] ||
    die "Consent Manager client secret is unavailable"

  jq -e --arg callback "$CALLBACK_URL" '
      (.grantTypes | index("authorization_code") != null)
      and (.grantTypes | index("refresh_token") != null)
      and (.callbackURLs | index($callback) != null)
      and .publicClient == false
      and .accessToken.type == "JWT"
      and ((.accessToken.bindingType // "None") | ascii_downcase) == "none"
      and (.accessToken.validateTokenBinding // false) == false
    ' "$oidc" >/dev/null ||
    die "Consent Manager OIDC configuration does not match required settings"

  ok "Consent Manager OAuth application configured (${client_id:0:8}...)" >&2

  printf '%s\t%s\t%s\n' "$app_id" "$client_id" "$client_secret"
}

ensure_api_authorization() {
  local app_id="$1"
  local api_id="$2"
  local auth="$TMP/authorized-apis.json"
  local existing missing http

  api "${IS_URL}/api/server/v1/applications/$app_id/authorized-apis" > "$auth"

  existing="$(
    jq -r --arg id "$api_id" '.[]? | select(.id==$id) | .id' "$auth" | head -1
  )"

  if [[ -z "$existing" ]]; then
    http="$(
      api \
        -o "$TMP/authorize-api.json" \
        -w '%{http_code}' \
        -X POST \
        -H 'Content-Type: application/json' \
        "${IS_URL}/api/server/v1/applications/$app_id/authorized-apis" \
        -d "$(jq -nc --arg id "$api_id" '{
          id:$id,
          policyIdentifier:"RBAC",
          scopes:["consents:read_self","consents:read_all"]
        }')"
    )"

    [[ "$http" == "200" || "$http" == "201" ]] || {
      cat "$TMP/authorize-api.json" >&2 || true
      die "could not authorize Consent Manager API Resource (HTTP $http)"
    }
  else
    missing="$(
      jq -c --arg id "$api_id" '
        (.[] | select(.id==$id) | [.authorizedScopes[].name]) as $have
        | ["consents:read_self","consents:read_all"] - $have
      ' "$auth"
    )"

    if [[ "$(jq 'length' <<<"$missing")" -gt 0 ]]; then
      http="$(
        api \
          -o "$TMP/authorize-api-patch.json" \
          -w '%{http_code}' \
          -X PATCH \
          -H 'Content-Type: application/json' \
          "${IS_URL}/api/server/v1/applications/$app_id/authorized-apis/$api_id" \
          -d "$(jq -nc --argjson added "$missing" '{
            addedScopes:$added,
            removedScopes:[]
          }')"
      )"

      [[ "$http" == "200" ]] || {
        cat "$TMP/authorize-api-patch.json" >&2 || true
        die "could not add missing Consent Manager authorized scopes (HTTP $http)"
      }
    fi
  fi

  api "${IS_URL}/api/server/v1/applications/$app_id/authorized-apis" > "$auth"

  for scope in consents:read_self consents:read_all; do
    jq -e --arg id "$api_id" --arg s "$scope" '
      .[] | select(.id==$id)
      | .authorizedScopes[]
      | select(.name==$s)
    ' "$auth" >/dev/null ||
      die "Consent Manager application is not authorized for $scope"
  done

  ok "Consent Manager application authorized for both consent scopes"
}

resolve_root_org_id() {
  local roles="$TMP/roles-all.json"
  api "${IS_URL}/scim2/v2/Roles?count=100" > "$roles"

  jq -r '
    [
      (.Resources // [])[]
      | select((.audience.type? // "" | ascii_downcase) == "organization")
      | .audience.value?
    ]
    | map(select(. != null and . != ""))
    | .[0] // empty
  ' "$roles"
}

ensure_role() {
  local name="$1"
  local permission="$2"
  local user_id="${3:-}"
  local org_id="$4"

  local search="$TMP/role-${name}.json"
  local current="$TMP/role-${name}-current.json"
  local out="$TMP/role-${name}-write.json"
  local role_id http payload

  api \
    -G "${IS_URL}/scim2/v2/Roles" \
    --data-urlencode "filter=displayName eq $name" \
    > "$search"

  role_id="$(
    jq -r '
      [
        (.Resources // [])[]
        | select((.audience.type? // "" | ascii_downcase) == "organization")
        | .id
      ]
      | .[0] // empty
    ' "$search"
  )"

  if [[ -z "$role_id" ]]; then
    if [[ -n "$user_id" ]]; then
      payload="$(
        jq -nc \
          --arg name "$name" \
          --arg permission "$permission" \
          --arg user "$user_id" \
          --arg org "$org_id" '
          {
            schemas:["urn:ietf:params:scim:schemas:extension:2.0:Role"],
            displayName:$name,
            audience:{value:$org,type:"organization"},
            users:[{value:$user}],
            permissions:[{value:$permission,display:$permission}]
          }
        '
      )"
    else
      payload="$(
        jq -nc \
          --arg name "$name" \
          --arg permission "$permission" \
          --arg org "$org_id" '
          {
            schemas:["urn:ietf:params:scim:schemas:extension:2.0:Role"],
            displayName:$name,
            audience:{value:$org,type:"organization"},
            users:[],
            permissions:[{value:$permission,display:$permission}]
          }
        '
      )"
    fi

    http="$(
      api \
        -o "$out" \
        -w '%{http_code}' \
        -X POST \
        -H 'Content-Type: application/scim+json' \
        "${IS_URL}/scim2/v2/Roles" \
        -d "$payload"
    )"

    [[ "$http" == "200" || "$http" == "201" ]] || {
      cat "$out" >&2 || true
      die "could not create $name (HTTP $http)"
    }

    role_id="$(jq -er '.id' "$out")"
  fi

  api "${IS_URL}/scim2/v2/Roles/$role_id" > "$current"

  local needs_repair=0
  jq -e --arg p "$permission" \
    '.permissions[]? | select(.value==$p)' \
    "$current" >/dev/null || needs_repair=1

  if [[ -n "$user_id" ]]; then
    jq -e --arg u "$user_id" \
      '.users[]? | select(.value==$u)' \
      "$current" >/dev/null || needs_repair=1
  fi

  if [[ "$needs_repair" == "1" ]]; then
    payload="$(
      jq -c \
        --arg name "$name" \
        --arg permission "$permission" \
        --arg user "$user_id" '
        {
          schemas:["urn:ietf:params:scim:schemas:extension:2.0:Role"],
          displayName:$name,
          audience:.audience,
          users:(
            ((.users // []) | map({value:.value}))
            + (if $user == "" then [] else [{value:$user}] end)
            | unique_by(.value)
          ),
          permissions:(
            ((.permissions // []) | map({value:.value,display:(.display // .value)}))
            + [{value:$permission,display:$permission}]
            | unique_by(.value)
          )
        }
      ' "$current"
    )"

    http="$(
      api \
        -o "$out" \
        -w '%{http_code}' \
        -X PUT \
        -H 'Content-Type: application/scim+json' \
        "${IS_URL}/scim2/v2/Roles/$role_id" \
        -d "$payload"
    )"

    [[ "$http" == "200" ]] || {
      cat "$out" >&2 || true
      die "could not repair $name (HTTP $http)"
    }

    api "${IS_URL}/scim2/v2/Roles/$role_id" > "$current"
  fi

  jq -e --arg p "$permission" \
    '.permissions[]? | select(.value==$p)' \
    "$current" >/dev/null ||
    die "$name is missing permission $permission"

  if [[ -n "$user_id" ]]; then
    jq -e --arg u "$user_id" \
      '.users[]? | select(.value==$u)' \
      "$current" >/dev/null ||
      die "$name is missing required user membership"
  fi

  ok "$name -> $permission" >&2
  printf '%s' "$role_id"
}

verify_org_role_audience() {
  local app_id="$1"
  local current="$TMP/app-role-audience.json"
  local audience

  api "${IS_URL}/api/server/v1/applications/$app_id" > "$current"

  audience="$(jq -r ".associatedRoles.allowedAudience // empty" "$current")"

  [[ "$audience" == "ORGANIZATION" ]] ||
    die "Consent Manager application role audience is $audience, expected ORGANIZATION"

  ok "Consent Manager application role audience = ORGANIZATION"
}

persist_local_env() {
  local client_id="$1"
  local client_secret="$2"

  CONSENT_MANAGER_CLIENT_ID_VALUE="$client_id" \
  CONSENT_MANAGER_CLIENT_SECRET_VALUE="$client_secret" \
  python3 - <<'PY'
from pathlib import Path
import os
import shlex

p = Path(".env")
text = p.read_text() if p.exists() else ""

values = {
    "CONSENT_MANAGER_CLIENT_ID": os.environ["CONSENT_MANAGER_CLIENT_ID_VALUE"],
    "CONSENT_MANAGER_CLIENT_SECRET": os.environ["CONSENT_MANAGER_CLIENT_SECRET_VALUE"],
}

lines = text.splitlines()
seen = set()
out = []

for line in lines:
    stripped = line.strip()
    replaced = False
    for key, value in values.items():
        if stripped.startswith(key + "="):
            out.append(f"{key}={shlex.quote(value)}")
            seen.add(key)
            replaced = True
            break
    if not replaced:
        out.append(line)

for key, value in values.items():
    if key not in seen:
        out.append(f"{key}={shlex.quote(value)}")

p.write_text("\n".join(out).rstrip() + "\n")
PY

  chmod 600 .env 2>/dev/null || true
  ok "Consent Manager client credentials stored only in local .env"
}

echo "============================================================"
echo "WSO2 FINANCIAL SERVICES CONSENT MANAGER PROVISIONING"
echo "============================================================"

wait_for_is

API_ID="$(ensure_resource)"

IFS=$'\t' read -r APP_ID CLIENT_ID CLIENT_SECRET < <(ensure_application)

[[ -n "$APP_ID" && -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]] ||
  die "could not resolve Consent Manager application credentials"

ensure_api_authorization "$APP_ID" "$API_ID"

ALICE_ID="$(
  api \
    -G "${IS_URL}/scim2/Users" \
    --data-urlencode 'filter=userName eq "alice"' \
  | jq -r '.Resources[0].id // empty'
)"

[[ -n "$ALICE_ID" ]] || die "Alice does not exist in WSO2 IS"

ORG_ID="$(resolve_root_org_id)"
[[ -n "$ORG_ID" ]] ||
  die "could not resolve the root organization id from existing organization roles"

CONSENT_ROLE_ID="$(ensure_role "ConsentPortalRole" "consents:read_self" "$ALICE_ID" "$ORG_ID")"
CCO_ROLE_ID="$(ensure_role "CustomerCareOfficerRole" "consents:read_all" "" "$ORG_ID")"

verify_org_role_audience "$APP_ID"
persist_local_env "$CLIENT_ID" "$CLIENT_SECRET"

echo
echo "[INFO] Rebuilding only WSO2 IS to apply the environment-backed portal configuration."

docker compose build wso2is

docker compose up -d \
  --no-deps \
  --force-recreate \
  wso2is

wait_for_is

echo
echo "[OK] WSO2 IS restarted with Consent Manager OAuth credentials"
echo "[OK] Consent Manager client id: ${CLIENT_ID:0:8}..."
echo "[OK] No client secret was written to a tracked file"
echo
echo "Next:"
echo "  ./demo/consent-manager-preflight.sh"
