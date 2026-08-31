#!/usr/bin/env bash
set -Eeuo pipefail

CONF="/home/wso2carbon/wso2is-7.2.0/repository/conf/deployment.toml"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

docker compose exec -T wso2is \
  cat "$CONF" > "$TMP"

required_contexts=(
  '(.*)/api/fs/consent/admin/(.*)'
  '(.*)/api/fs/consent/(.*)'
  '(.*)/fs/authenticationendpoint/(.*)'
  '(.*)/api/fs/event-notifications/(.*)'
  '(.*)/consentmgr/(.*)'
)

for context in "${required_contexts[@]}"; do
  if ! grep -Fq "context = \"$context\"" "$TMP"; then
    echo "Missing FS resource access-control context: $context" >&2
    exit 1
  fi
done

basic_count="$(
  grep -Fc \
    'allowed_auth_handlers = ["BasicAuthentication"]' \
    "$TMP" \
    || true
)"

if (( basic_count < 2 )); then
  echo \
    "Expected at least two Financial Services BasicAuthentication " \
    "resource rules; found $basic_count" \
    >&2
  exit 1
fi

echo "[OK] Financial Services IS resource access-control active"
