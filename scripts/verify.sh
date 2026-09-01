#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
fail=0
check(){ local label=$1; shift; if "$@"; then printf '  [OK] %s\n' "$label"; else printf '  [FAIL] %s\n' "$label"; fail=1; fi; }
verify_fapi_hybrid_flow() {
  local keys=".state/demo-access/application-keys.json"
  local client_id app_id
  local apps oidc

  [[ -s "$keys" ]] || return 1

  client_id="$(jq -r '.consumerKey // empty' "$keys")"
  [[ -n "$client_id" ]] || return 1

  apps="$(
    curl -ksS \
      -u "${IS_ADMIN_USER:-admin}:${IS_ADMIN_PASSWORD:-admin}" \
      -G "https://localhost:${IS_HTTPS_PORT:-9446}/api/server/v1/applications" \
      --data-urlencode "filter=clientId eq $client_id"
  )" || return 1

  app_id="$(jq -r '.applications[0].id // empty' <<<"$apps")"
  [[ -n "$app_id" ]] || return 1

  oidc="$(
    curl -ksS \
      -u "${IS_ADMIN_USER:-admin}:${IS_ADMIN_PASSWORD:-admin}" \
      "https://localhost:${IS_HTTPS_PORT:-9446}/api/server/v1/applications/$app_id/inbound-protocols/oidc"
  )" || return 1

  jq -e '
    .isFAPIApplication == true
    and .hybridFlow.enable == true
    and .hybridFlow.responseType == "code id_token"
    and .clientAuthentication.tokenEndpointAuthMethod == "tls_client_auth"
    and .accessToken.bindingType == "certificate"
    and .requestObject.requestObjectSigningAlg == "PS256"
    and .pushAuthorizationRequest.requirePushAuthorizationRequest == true
  ' <<<"$oidc" >/dev/null
}

log "Runtime verification"
check "Mock bank health" curl -fsS "http://localhost:${BANK_BACKEND_PORT:-8080}/healthz" -o /dev/null
summary=$(curl -fsS "http://localhost:${BANK_BACKEND_PORT:-8080}/demo/summary" 2>/dev/null || echo '{}')
check "Mock bank has >=20 accounts" bash -c "test \$(jq -r '.accounts // 0' <<< '$summary') -ge 20"
check "Mock bank has >=400 transactions" bash -c "test \$(jq -r '.transactions // 0' <<< '$summary') -ge 400"
check "Identity Server JWKS" curl -ksSf "https://localhost:${IS_HTTPS_PORT:-9446}/oauth2/jwks" -o /dev/null
check "IS FAPI hybrid code id_token flow enabled" verify_fapi_hybrid_flow
check "IS FS BasicAuthentication access control" ./scripts/check-is-fs-access-control.sh
check "API Manager management surface" bash -c "curl -ksSf https://localhost:${APIM_HTTPS_PORT:-9443}/services/Version >/dev/null || curl -ksSf https://localhost:${APIM_HTTPS_PORT:-9443}/publisher >/dev/null"
check "API Manager live TLS certificate matches generated demo PKI" bash -c './scripts/check-apim-tls-certificate.sh >/dev/null'
# Consent endpoint varies slightly across Accelerator releases; 401/403/405 proves the webapp/resource exists, while 404 is a hard failure.
code=$(curl -ksS -o /tmp/ob-consent-check -w '%{http_code}' "https://localhost:${IS_HTTPS_PORT:-9446}/api/fs/consent/manage/consents" || true)
if [[ "$code" == "404" || "$code" == "000" ]]; then printf '  [FAIL] Financial Services consent surface (HTTP %s)\n' "$code"; fail=1; else printf '  [OK] Financial Services consent surface responds (HTTP %s)\n' "$code"; fi
check "FS MTLS policy extracted" bash -c "find .state/policies -name mtlsEnforcementPolicy.j2 | grep -q ."
check "FS Consent policy extracted" bash -c "find .state/policies -name consentEnforcementPolicy.j2 | grep -q ."
check "FS Dynamic Endpoint policy extracted" bash -c "find .state/policies -name dynamicEndpointPolicy.j2 | grep -q ."
check "APIM Accounts API bootstrapped" test -s .state/bootstrap/AcmeBankAccountsAPI.id
check "APIM Payments API bootstrapped" test -s .state/bootstrap/AcmeBankPaymentsAPI.id
check "APIM CoF API bootstrapped" test -s .state/bootstrap/AcmeBankConfirmationOfFundsAPI.id
check "TPP client certificate exists" test -s .state/certs/tpp.crt
check "IS public certificate exists for backend ARI verification" test -s .state/certs/wso2is.crt
check "Shared truststore exists" test -s .state/certs/client-truststore.p12
(( fail == 0 )) || fatal "One or more runtime gates failed. Run ./logs.sh before treating the demo as ready."
log "All implemented runtime gates passed"
