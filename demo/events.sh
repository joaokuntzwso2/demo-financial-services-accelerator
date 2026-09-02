#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

[[ -f .env ]] && set -a && source .env && set +a
[[ -f .state/demo-access/demo-access.env ]] && set -a && source .state/demo-access/demo-access.env && set +a

IS_URL="${IS_PUBLIC:-${IS_URL:-https://localhost:${IS_HTTPS_PORT:-9446}}}"
IS_ADMIN_USER="${IS_ADMIN_USER:-${WSO2_ADMIN_USER:-admin}}"
IS_ADMIN_PASSWORD="${IS_ADMIN_PASSWORD:-${WSO2_ADMIN_PASSWORD:-admin}}"
PORTAL_URL="${FINLINK_PORTAL_URL:-https://localhost:9445}"

CA=".state/certs/ca.crt"
STATE_DIR=".state/events"
EVENT_TYPE="urn_uk_org_openbanking_events_consent-authorization-revoked"

mkdir -p "$STATE_DIR"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_runtime() {
  [[ -s "$CA" ]] || fail "$CA is missing"
  command -v curl >/dev/null || fail "curl is required"
  command -v jq >/dev/null || fail "jq is required"
  command -v python3 >/dev/null || fail "python3 is required"
  docker compose ps mysql >/dev/null 2>&1 ||
    fail "docker compose mysql service is unavailable"
}

finlink_client_id() {
  curl -sS \
    --cacert "$CA" \
    "$PORTAL_URL/healthz" |
    jq -er '.client_id'
}

encode_base64() {
  base64 | tr -d '\r\n'
}

db_event_json() {
  local notification_id="$1"

  docker compose exec -T mysql sh -lc "
    mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" fs_consentdb -N -B -e \"
      SELECT JSON_OBJECT(
        'notification_id', N.NOTIFICATION_ID,
        'client_id', N.CLIENT_ID,
        'resource_id', N.RESOURCE_ID,
        'status', N.STATUS,
        'updated_timestamp', N.UPDATED_TIMESTAMP,
        'event_type', E.EVENT_TYPE,
        'event_info', JSON_EXTRACT(E.EVENT_INFO, '\\\$')
      )
      FROM FS_NOTIFICATION N
      JOIN FS_NOTIFICATION_EVENT E
        ON E.NOTIFICATION_ID = N.NOTIFICATION_ID
      WHERE N.NOTIFICATION_ID = '$notification_id'
      LIMIT 1;
    \" 2>/dev/null
  "
}

latest_notification_id() {
  docker compose exec -T mysql sh -lc "
    mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" fs_consentdb -N -B -e \"
      SELECT N.NOTIFICATION_ID
      FROM FS_NOTIFICATION N
      JOIN FS_NOTIFICATION_EVENT E
        ON E.NOTIFICATION_ID = N.NOTIFICATION_ID
      WHERE E.EVENT_TYPE = '$EVENT_TYPE'
      ORDER BY N.UPDATED_TIMESTAMP DESC, E.EVENT_ID DESC
      LIMIT 1;
    \" 2>/dev/null
  "
}

decode_set_json() {
  local jwt="$1"

  JWT="$jwt" python3 - <<'PY'
import base64
import json
import os

token = os.environ["JWT"]
parts = token.split(".")
if len(parts) != 3:
    raise SystemExit("invalid SET/JWT")

def decode(part):
    part += "=" * (-len(part) % 4)
    return json.loads(base64.urlsafe_b64decode(part.encode()).decode())

print(json.dumps({
    "header": decode(parts[0]),
    "payload": decode(parts[1]),
}, separators=(",", ":")))
PY
}

poll_for_notification() {
  local client_id="$1"
  local notification_id="$2"
  local poll_request poll_encoded http jwt attempt

  poll_request='{"returnImmediately":true,"maxEvents":100}'
  poll_encoded="$(printf '%s' "$poll_request" | encode_base64)"

  for attempt in {1..20}; do
    http="$(
      curl -sS \
        --cacert "$CA" \
        -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
        -o /tmp/finlink-event-poll.json \
        -w '%{http_code}' \
        -X POST \
        -H "x-wso2-client-id: ${client_id}" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "request=${poll_encoded}" \
        "${IS_URL}/api/fs/event-notifications/events"
    )"

    [[ "$http" == "200" ]] ||
      fail "Event Polling API returned HTTP $http: $(cat /tmp/finlink-event-poll.json)"

    jwt="$(
      TARGET_NOTIFICATION_ID="$notification_id" \
      python3 - /tmp/finlink-event-poll.json <<'PY'
import base64
import json
import os
import sys

target = os.environ["TARGET_NOTIFICATION_ID"]
response = json.load(open(sys.argv[1]))

for set_id, token in (response.get("sets") or {}).items():
    try:
        part = token.split(".")[1]
        part += "=" * (-len(part) % 4)
        payload = json.loads(base64.urlsafe_b64decode(part.encode()).decode())
    except Exception:
        continue

    if set_id == target or payload.get("jti") == target:
        print(token)
        break
PY
    )"

    if [[ -n "$jwt" ]]; then
      printf '%s' "$jwt"
      return
    fi

    sleep 1
  done

  fail "signed SET for notification $notification_id was not returned by polling"
}

publish_revocation() {
  local consent_id=""
  local previous_status=""
  local current_status=""
  local token_fp=""
  local json_output=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --consent-id)
        consent_id="$2"; shift 2 ;;
      --previous-status)
        previous_status="$2"; shift 2 ;;
      --current-status)
        current_status="$2"; shift 2 ;;
      --token-fingerprint)
        token_fp="$2"; shift 2 ;;
      --json)
        json_output=1; shift ;;
      *)
        fail "unknown publish-revocation argument: $1" ;;
    esac
  done

  [[ -n "$consent_id" ]] || fail "--consent-id is required"
  [[ -n "$previous_status" ]] || fail "--previous-status is required"
  [[ -n "$current_status" ]] || fail "--current-status is required"
  [[ -n "$token_fp" ]] || fail "--token-fingerprint is required"

  local client_id event_json encoded http notification_id persisted jwt set_json
  local state_file

  client_id="$(finlink_client_id)"

  event_json="$(
    jq -nc \
      --arg event_type "$EVENT_TYPE" \
      --arg consent_id "$consent_id" \
      --arg client_id "$client_id" \
      --arg previous_status "$previous_status" \
      --arg current_status "$current_status" \
      --arg token_fp "$token_fp" \
      --arg occurred_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      {
        ($event_type): {
          resourceID:$consent_id,
          consentId:$consent_id,
          clientId:$client_id,
          previousConsentStatus:$previous_status,
          consentStatus:$current_status,
          reason:"Consent revoked by the customer in WSO2 Consent Manager",
          occurredAt:$occurred_at,
          tokenFingerprint:$token_fp
        }
      }
    '
  )"

  encoded="$(printf '%s' "$event_json" | encode_base64)"

  http="$(
    curl -sS \
      --cacert "$CA" \
      -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
      -o /tmp/finlink-event-create.json \
      -w '%{http_code}' \
      -X POST \
      -H "x-wso2-client-id: ${client_id}" \
      -H "x-wso2-resource-id: ${consent_id}" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "request=${encoded}" \
      "${IS_URL}/api/fs/event-notifications/create-events"
  )"

  [[ "$http" == "200" || "$http" == "201" ]] ||
    fail "Event Creation API returned HTTP $http: $(cat /tmp/finlink-event-create.json)"

  notification_id="$(
    jq -er '
      .notificationsID
      // .notificationID
      // .notificationId
    ' /tmp/finlink-event-create.json
  )"

  persisted="$(db_event_json "$notification_id")"
  [[ -n "$persisted" ]] ||
    fail "notification $notification_id was not persisted by the Accelerator"

  printf '%s' "$persisted" |
    jq -e \
      --arg nid "$notification_id" \
      --arg cid "$consent_id" \
      --arg type "$EVENT_TYPE" '
      .notification_id == $nid
      and .resource_id == $cid
      and .event_type == $type
    ' >/dev/null ||
    fail "persisted event does not match notification/consent/event type"

  jwt="$(poll_for_notification "$client_id" "$notification_id")"
  set_json="$(decode_set_json "$jwt")"

  printf '%s' "$set_json" |
    jq -e \
      --arg nid "$notification_id" \
      --arg client "$client_id" \
      --arg type "$EVENT_TYPE" '
      .payload.jti == $nid
      and .payload.aud == $client
      and ((.payload.events // {}) | has($type))
    ' >/dev/null ||
    fail "signed SET does not correlate to the created notification"

  state_file="$STATE_DIR/${notification_id}.json"

  jq -nc \
    --argjson persisted "$persisted" \
    --argjson set "$set_json" \
    --arg notification_id "$notification_id" \
    --arg consent_id "$consent_id" \
    --arg token_fp "$token_fp" \
    '{
      notification_id:$notification_id,
      consent_id:$consent_id,
      token_fingerprint:$token_fp,
      persisted:$persisted,
      set:$set
    }' > "$state_file"

  if [[ "$json_output" == "1" ]]; then
    jq -nc \
      --arg notification_id "$notification_id" \
      --arg consent_id "$consent_id" \
      --arg event_type "$EVENT_TYPE" \
      --arg set_jti "$(printf '%s' "$set_json" | jq -r '.payload.jti')" \
      '{
        notification_id:$notification_id,
        consent_id:$consent_id,
        event_type:$event_type,
        set_jti:$set_jti,
        delivered:true
      }'
  else
    echo "[OK] Financial Services event created: $notification_id" >&2
    show_notification "$notification_id"
  fi
}

record_enforcement() {
  local notification_id=""
  local before_http=""
  local after_http=""
  local token_fp=""
  local rejected=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --notification-id)
        notification_id="$2"; shift 2 ;;
      --before-http)
        before_http="$2"; shift 2 ;;
      --after-http)
        after_http="$2"; shift 2 ;;
      --token-fingerprint)
        token_fp="$2"; shift 2 ;;
      --rejected)
        rejected="$2"; shift 2 ;;
      *)
        fail "unknown record-enforcement argument: $1" ;;
    esac
  done

  [[ -n "$notification_id" ]] || fail "--notification-id is required"
  [[ -n "$before_http" ]] || fail "--before-http is required"
  [[ -n "$after_http" ]] || fail "--after-http is required"
  [[ -n "$token_fp" ]] || fail "--token-fingerprint is required"
  [[ "$rejected" == "true" || "$rejected" == "false" ]] ||
    fail "--rejected must be true or false"

  jq -nc \
    --arg before_http "$before_http" \
    --arg after_http "$after_http" \
    --arg token_fp "$token_fp" \
    --argjson rejected "$rejected" '
    {
      before_http:($before_http|tonumber),
      after_http:($after_http|tonumber),
      token_fingerprint:$token_fp,
      mtls:true,
      rejected:$rejected
    }' > "$STATE_DIR/${notification_id}.enforcement.json"
}

show_notification() {
  local notification_id="$1"
  local persisted state_file enforcement_file set_json
  local client_id resource_id status event_type event_info
  local set_alg set_jti set_aud set_event_type

  persisted="$(db_event_json "$notification_id")"
  [[ -n "$persisted" ]] ||
    fail "notification $notification_id was not found in Accelerator persistence"

  state_file="$STATE_DIR/${notification_id}.json"
  enforcement_file="$STATE_DIR/${notification_id}.enforcement.json"

  if [[ -s "$state_file" ]]; then
    set_json="$(jq -c '.set' "$state_file")"
  else
    client_id="$(printf '%s' "$persisted" | jq -r '.client_id')"
    local jwt
    jwt="$(poll_for_notification "$client_id" "$notification_id")"
    set_json="$(decode_set_json "$jwt")"
  fi

  client_id="$(printf '%s' "$persisted" | jq -r '.client_id')"
  resource_id="$(printf '%s' "$persisted" | jq -r '.resource_id')"
  status="$(printf '%s' "$persisted" | jq -r '.status')"
  event_type="$(printf '%s' "$persisted" | jq -r '.event_type')"
  event_info="$(printf '%s' "$persisted" | jq -c '.event_info')"

  set_alg="$(printf '%s' "$set_json" | jq -r '.header.alg // "unknown"')"
  set_jti="$(printf '%s' "$set_json" | jq -r '.payload.jti // empty')"
  set_aud="$(printf '%s' "$set_json" | jq -r '.payload.aud // empty')"
  set_event_type="$(
    printf '%s' "$set_json" |
      jq -r '.payload.events // {} | keys[0] // empty'
  )"

  echo
  echo "============================================================"
  echo "FINANCIAL SERVICES EVENT"
  echo "============================================================"
  printf '%-20s %s\n' "Notification ID" "$notification_id"
  printf '%-20s %s\n' "Event" "$event_type"
  printf '%-20s %s\n' "Consent / resource" "$resource_id"
  printf '%-20s %s\n' "Client" "$client_id"
  printf '%-20s %s\n' "Queue status" "$status"

  echo
  echo "Persisted event details:"
  printf '%s\n' "$event_info" | jq .

  echo
  echo "============================================================"
  echo "SIGNED SECURITY EVENT TOKEN"
  echo "============================================================"
  printf '%-20s %s\n' "JWT alg" "$set_alg"
  printf '%-20s %s\n' "SET jti" "$set_jti"
  printf '%-20s %s\n' "SET aud" "$set_aud"
  printf '%-20s %s\n' "SET event type" "$set_event_type"

  [[ "$set_jti" == "$notification_id" ]] ||
    fail "SET jti does not match notification ID"
  [[ "$set_aud" == "$client_id" ]] ||
    fail "SET audience does not match client ID"
  [[ "$set_event_type" == "$event_type" ]] ||
    fail "SET event type does not match persisted event type"

  echo
  echo "[OK] Event Creation -> Accelerator persistence -> signed SET correlated"

  if [[ -s "$enforcement_file" ]]; then
    local before_http after_http token_fp rejected

    before_http="$(jq -r '.before_http' "$enforcement_file")"
    after_http="$(jq -r '.after_http' "$enforcement_file")"
    token_fp="$(jq -r '.token_fingerprint' "$enforcement_file")"
    rejected="$(jq -r '.rejected' "$enforcement_file")"

    echo
    echo "============================================================"
    echo "CORRELATED ENFORCEMENT"
    echo "============================================================"
    printf '%-20s HTTP %s\n' "Before revoke" "$before_http"
    printf '%-20s HTTP %s\n' "After revoke" "$after_http"
    printf '%-20s %s\n' "Token fingerprint" "$token_fp"
    printf '%-20s %s\n' "mTLS" "same client"
    printf '%-20s %s\n' "Rejected" "$rejected"

    [[ "$before_http" == "200" ]] ||
      fail "correlated pre-revocation request was not HTTP 200"
    [[ "$after_http" != "200" && "$rejected" == "true" ]] ||
      fail "correlated post-revocation request was not rejected"

    echo
    echo "[OK] Financial Services event correlated with live consent enforcement"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  ./demo/events.sh
  ./demo/events.sh --notification-id <id>
  ./demo/events.sh publish-revocation \
    --consent-id <id> \
    --previous-status <status> \
    --current-status <status> \
    --token-fingerprint <fingerprint> \
    [--json]
  ./demo/events.sh record-enforcement \
    --notification-id <id> \
    --before-http <status> \
    --after-http <status> \
    --token-fingerprint <fingerprint> \
    --rejected <true|false>
EOF
}

require_runtime

case "${1:-}" in
  publish-revocation)
    shift
    publish_revocation "$@"
    ;;
  record-enforcement)
    shift
    record_enforcement "$@"
    ;;
  --notification-id)
    [[ -n "${2:-}" ]] || fail "--notification-id requires a value"
    show_notification "$2"
    ;;
  -h|--help)
    usage
    ;;
  "")
    LATEST="$(latest_notification_id)"
    [[ -n "$LATEST" ]] ||
      fail "no Financial Services consent-revocation event exists yet"
    show_notification "$LATEST"
    ;;
  *)
    fail "unknown argument: $1"
    ;;
esac
