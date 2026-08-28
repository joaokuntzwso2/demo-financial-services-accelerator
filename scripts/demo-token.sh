#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

STATE=".state/demo-access/demo-access.json"
[[ -s "$STATE" ]] || {
  echo "ERROR: $STATE not found. Run ./start.sh first." >&2
  exit 1
}

USER_NAME="${1:-demo}"
REQUESTED_SCOPES="${2:-}"

CONSUMER_KEY="$(jq -er '.application.consumerKey' "$STATE")"
CONSUMER_SECRET="$(jq -er '.application.consumerSecret' "$STATE")"

USER_JSON="$(
  jq -c --arg u "$USER_NAME" '.users[] | select(.username==$u)' "$STATE" | head -1
)"
[[ -n "$USER_JSON" ]] || {
  echo "Unknown demo user: $USER_NAME" >&2
  echo "Available: $(jq -r '[.users[].username] | join(", ")' "$STATE")" >&2
  exit 1
}

PASSWORD="$(jq -r '.password' <<<"$USER_JSON")"
if [[ -z "$REQUESTED_SCOPES" ]]; then
  REQUESTED_SCOPES="$(jq -r '.scopes | join(" ")' <<<"$USER_JSON")"
fi

curl -ksS \
  -u "$CONSUMER_KEY:$CONSUMER_SECRET" \
  -X POST 'https://localhost:9446/oauth2/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=password' \
  --data-urlencode "username=$USER_NAME" \
  --data-urlencode "password=$PASSWORD" \
  --data-urlencode "scope=$REQUESTED_SCOPES" |
jq
