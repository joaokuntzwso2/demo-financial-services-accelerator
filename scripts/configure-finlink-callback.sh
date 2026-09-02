#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

IS_PUBLIC="${IS_PUBLIC_URL:-https://localhost:9446}"
IS_ADMIN_USER="${IS_ADMIN_USER:-admin}"
IS_ADMIN_PASSWORD="${IS_ADMIN_PASSWORD:-admin}"
CALLBACK="${FINLINK_REDIRECT_URI:-https://localhost:9445/callback}"
LEGACY_CALLBACK="${FINLINK_LEGACY_REDIRECT_URI:-https://localhost/callback}"
CALLBACK_PATTERN="regexp=(${LEGACY_CALLBACK}|${CALLBACK})"

STATE=".state/demo-access/demo-access.json"
CA=".state/certs/ca.crt"

for FILE in "$STATE" "$CA"; do
  [[ -s "$FILE" ]] || {
    echo "ERROR: required file missing: $FILE" >&2
    exit 1
  }
done

for CMD in curl jq; do
  command -v "$CMD" >/dev/null 2>&1 || {
    echo "ERROR: $CMD is required" >&2
    exit 1
  }
done

CLIENT_ID="$(jq -er '.application.consumerKey' "$STATE")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsS \
  --cacert "$CA" \
  -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
  -G "$IS_PUBLIC/api/server/v1/applications" \
  --data-urlencode "filter=clientId eq $CLIENT_ID" \
  > "$TMP/apps.json"

APP_ID="$(jq -er '.applications[0].id // empty' "$TMP/apps.json")"

curl -fsS \
  --cacert "$CA" \
  -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
  "$IS_PUBLIC/api/server/v1/applications/$APP_ID/inbound-protocols/oidc" \
  > "$TMP/oidc-before.json"

jq -e '.isFAPIApplication == true' "$TMP/oidc-before.json" >/dev/null

if jq -e \
  --arg pattern "$CALLBACK_PATTERN" \
  '.callbackURLs == [$pattern]' \
  "$TMP/oidc-before.json" \
  >/dev/null
then
  echo "[OK] FinLink callback regex already registered"
  exit 0
fi

if ! jq -e \
  --arg legacy "$LEGACY_CALLBACK" \
  --arg callback "$CALLBACK" \
  '
    (.callbackURLs // []) as $urls
    | ($urls | type) == "array"
    and
    ($urls | all(. == $legacy or . == $callback))
  ' \
  "$TMP/oidc-before.json" \
  >/dev/null
then
  echo "ERROR: refusing to overwrite unexpected callback configuration" >&2
  jq '.callbackURLs' "$TMP/oidc-before.json" >&2
  exit 1
fi

jq \
  --arg pattern "$CALLBACK_PATTERN" \
  '
    .callbackURLs = [$pattern]
    | del(.clientSecret)
  ' \
  "$TMP/oidc-before.json" \
  > "$TMP/oidc-update.json"

HTTP="$(
  curl -sS \
    --cacert "$CA" \
    -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
    -o "$TMP/oidc-put.json" \
    -w '%{http_code}' \
    -X PUT \
    "$IS_PUBLIC/api/server/v1/applications/$APP_ID/inbound-protocols/oidc" \
    -H 'Content-Type: application/json' \
    --data-binary @"$TMP/oidc-update.json"
)"

[[ "$HTTP" == "200" || "$HTTP" == "201" ]] || {
  cat "$TMP/oidc-put.json" >&2 || true
  echo "ERROR: callback registration failed (HTTP $HTTP)" >&2
  exit 1
}

curl -fsS \
  --cacert "$CA" \
  -u "${IS_ADMIN_USER}:${IS_ADMIN_PASSWORD}" \
  "$IS_PUBLIC/api/server/v1/applications/$APP_ID/inbound-protocols/oidc" \
  > "$TMP/oidc-after.json"

jq -e '.isFAPIApplication == true' "$TMP/oidc-after.json" >/dev/null
jq -e \
  --arg pattern "$CALLBACK_PATTERN" \
  '.callbackURLs == [$pattern]' \
  "$TMP/oidc-after.json" \
  >/dev/null

echo "[OK] FinLink callback registered: $CALLBACK"
echo "[OK] legacy callback preserved: $LEGACY_CALLBACK"
echo "[OK] callback regex: $CALLBACK_PATTERN"
echo "[OK] FAPI application flag preserved"
