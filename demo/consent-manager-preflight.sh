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
CALLBACK_URL="${IS_URL}/consentmgr/scp_oauth2_callback"
QUIET=0

[[ "${1:-}" == "--quiet" ]] && QUIET=1

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

api() {
  curl -sS \
    --cacert .state/certs/ca.crt \
    -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
    "$@"
}

[[ -s .state/certs/ca.crt ]] || fail ".state/certs/ca.crt is missing"

PORTAL_HTTP="$(
  curl -sS \
    --cacert .state/certs/ca.crt \
    -o /tmp/finlink-consentmgr.html \
    -w '%{http_code}' \
    "${IS_URL}/consentmgr/" || true
)"

case "$PORTAL_HTTP" in
  200|301|302|303|307|308) ;;
  *) fail "Consent Manager is not reachable at ${IS_URL}/consentmgr/ (HTTP $PORTAL_HTTP)" ;;
esac

SCOPES_ALL="$(api "${IS_URL}/api/server/v1/scopes")"

RESOURCE_ID="$(
  printf '%s' "$SCOPES_ALL" |
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
  '
)"

[[ -n "$RESOURCE_ID" ]] ||
  fail "no API Resource contains both consents:read_self and consents:read_all"

APPS="$(
  api \
    -G "${IS_URL}/api/server/v1/applications" \
    --data-urlencode "filter=name eq $APP_NAME" \
    --data-urlencode "limit=100"
)"

APP_ID="$(
  printf '%s' "$APPS" |
  jq -r --arg name "$APP_NAME" '
    [
      .. | objects
      | select((.name? // "") == $name)
      | .id?
    ]
    | map(select(. != null and . != ""))
    | .[0] // empty
  '
)"

[[ -n "$APP_ID" ]] || fail "$APP_NAME application was not found"

APP="$(api "${IS_URL}/api/server/v1/applications/$APP_ID")"

printf '%s' "$APP" |
  jq -e '.associatedRoles.allowedAudience == "ORGANIZATION"' >/dev/null ||
  fail "Consent Manager application role audience is not ORGANIZATION"

OIDC="$(api "${IS_URL}/api/server/v1/applications/$APP_ID/inbound-protocols/oidc")"

printf '%s' "$OIDC" |
  jq -e --arg callback "$CALLBACK_URL" '
    (.grantTypes | index("authorization_code") != null)
    and (.grantTypes | index("refresh_token") != null)
    and (.callbackURLs | index($callback) != null)
    and .publicClient == false
    and .accessToken.type == "JWT"
    and ((.accessToken.bindingType // "None") | ascii_downcase) == "none"
    and (.accessToken.validateTokenBinding // false) == false
  ' >/dev/null ||
  fail "Consent Manager OIDC settings are incorrect"

AUTH="$(api "${IS_URL}/api/server/v1/applications/$APP_ID/authorized-apis")"

for SCOPE_NAME in consents:read_self consents:read_all; do
  printf '%s' "$AUTH" |
    jq -e --arg id "$RESOURCE_ID" --arg s "$SCOPE_NAME" '
      .[] | select(.id==$id)
      | .authorizedScopes[]
      | select(.name==$s)
    ' >/dev/null ||
    fail "Consent Manager application is missing authorized scope $SCOPE_NAME"
done

ALICE_ID="$(
  api \
    -G "${IS_URL}/scim2/Users" \
    --data-urlencode 'filter=userName eq "alice"' |
  jq -r '.Resources[0].id // empty'
)"

[[ -n "$ALICE_ID" ]] || fail "Alice was not found in WSO2 IS"

ROLES="$(
  api \
    -G "${IS_URL}/scim2/v2/Roles" \
    --data-urlencode 'filter=displayName eq "ConsentPortalRole"'
)"

ROLE_ID="$(
  printf '%s' "$ROLES" |
  jq -r '
    [
      (.Resources // [])[]
      | select((.audience.type? // "" | ascii_downcase) == "organization")
      | .id
    ]
    | .[0] // empty
  '
)"

[[ -n "$ROLE_ID" ]] || fail "organization-level ConsentPortalRole was not found"

ROLE="$(api "${IS_URL}/scim2/v2/Roles/$ROLE_ID")"

printf '%s' "$ROLE" |
  jq -e '.permissions[]? | select(.value=="consents:read_self")' >/dev/null ||
  fail "ConsentPortalRole does not have consents:read_self"

printf '%s' "$ROLE" |
  jq -e --arg uid "$ALICE_ID" '.users[]? | select(.value==$uid)' >/dev/null ||
  fail "Alice is not assigned to ConsentPortalRole"

[[ -n "${CONSENT_MANAGER_CLIENT_ID:-}" ]] ||
  fail "CONSENT_MANAGER_CLIENT_ID is not loaded from local .env"

[[ -n "${CONSENT_MANAGER_CLIENT_SECRET:-}" ]] ||
  fail "CONSENT_MANAGER_CLIENT_SECRET is not loaded from local .env"

if [[ "$QUIET" == "0" ]]; then
  echo "[OK] Consent Manager portal reachable: ${IS_URL}/consentmgr/"
  echo "[OK] Financial Services Consent Manager API Resource found"
  echo "[OK] consents:read_self + consents:read_all present"
  echo "[OK] FinLink Consent Manager OAuth application present"
  echo "[OK] application role audience = ORGANIZATION"
  echo "[OK] authorization_code + refresh_token configured"
  echo "[OK] callback configured: $CALLBACK_URL"
  echo "[OK] JWT access token with token binding None"
  echo "[OK] application authorized for both consent scopes"
  echo "[OK] ConsentPortalRole -> consents:read_self"
  echo "[OK] Alice assigned to ConsentPortalRole"
  echo "[OK] OAuth client credentials externalized via local environment"
  echo
  echo "Static/runtime preflight passed."
  echo "The next proof is an actual Alice login to Consent Manager."
fi
