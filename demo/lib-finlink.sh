#!/usr/bin/env bash

FINLINK_ROOT="${ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)}"
FINLINK_URL="${FINLINK_PORTAL_URL:-https://localhost:9445}"
FINLINK_CA="$FINLINK_ROOT/.state/certs/ca.crt"

finlink_ensure() {
  "$FINLINK_ROOT/demo/finlink.sh" start --no-open >/dev/null
}

finlink_curl() {
  curl -fsS --cacert "$FINLINK_CA" "$@"
}

finlink_start_and_wait() {
  local DOMAIN="$1"
  local OUT AUTH_URL USERNAME PASSWORD CONSENT_ID

  OUT="$(
    finlink_curl \
      -X POST \
      "$FINLINK_URL/api/start?domain=$DOMAIN" \
      -H 'Content-Type: application/json' \
      -d '{}'
  )"

  AUTH_URL="$(jq -er '.auth_url' <<<"$OUT")"
  USERNAME="$(jq -er '.username' <<<"$OUT")"
  PASSWORD="$(jq -er '.password' <<<"$OUT")"
  CONSENT_ID="$(jq -er '.consent_id' <<<"$OUT")"

  echo
  echo "CONSENT=$CONSENT_ID"
  echo "LOGIN=$USERNAME / $PASSWORD"
  echo
  echo "[ACTION] Authenticate and approve the real consent in WSO2."
  echo "[ACTION] Callback capture and code exchange are automatic."
  echo

  open "$AUTH_URL"

  for _ in $(seq 1 600); do
    if finlink_curl "$FINLINK_URL/api/state" \
      | jq -e --arg d "$DOMAIN" '.domains[$d].authorized == true' >/dev/null
    then
      echo "[OK] $DOMAIN authorised"
      return 0
    fi
    sleep 0.5
  done

  echo "ERROR: authorization timeout for $DOMAIN" >&2
  return 1
}

finlink_action() {
  local DOMAIN="$1"
  local ACTION="$2"
  local EXTRA="${3-}"

  if [[ -z "$EXTRA" ]]; then
    EXTRA="{}"
  fi

  jq -nc \
    --arg domain "$DOMAIN" \
    --arg action "$ACTION" \
    --argjson extra "$EXTRA" \
    '{domain:$domain,action:$action} + $extra' \
    | finlink_curl \
        -X POST \
        "$FINLINK_URL/api/action" \
        -H 'Content-Type: application/json' \
        --data-binary @-
}
