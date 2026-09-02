#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

PORTAL_URL="${FINLINK_PORTAL_URL:-https://localhost:9445}"
CA=".state/certs/ca.crt"
REUSE=0
[[ "${1:-}" == "--reuse" ]] && REUSE=1

die() {
  echo "ERROR: $*" >&2
  exit 1
}

portal_get() {
  curl -fsS --cacert "$CA" "$1"
}

portal_post() {
  curl -fsS --cacert "$CA" -X POST "$1"
}

"$ROOT/demo/finlink.sh" start --no-open >/dev/null

STATE="$(portal_get "$PORTAL_URL/api/state")"
AUTHORISED="$(printf '%s' "$STATE" | jq -r '.domains.accounts.authorized // false')"

if [[ "$AUTHORISED" != "true" ]]; then
  if [[ "$REUSE" == "1" ]]; then
    die "--reuse requested but Accounts is not currently authorized"
  fi

  START="$(portal_post "$PORTAL_URL/api/start?domain=accounts")"
  CONSENT_ID="$(printf '%s' "$START" | jq -er '.consent_id')"
  AUTH_URL="$(printf '%s' "$START" | jq -er '.auth_url')"
  USERNAME="$(printf '%s' "$START" | jq -er '.username')"
  PASSWORD="$(printf '%s' "$START" | jq -er '.password')"

  echo "CONSENT=$CONSENT_ID"
  echo "LOGIN=$USERNAME / $PASSWORD"
  echo "[ACTION] Authenticate Alice and approve the real Accounts consent in WSO2."
  open "$AUTH_URL"

  DEADLINE=$(( $(date +%s) + 300 ))
  while :; do
    STATE="$(portal_get "$PORTAL_URL/api/state")"
    if printf '%s' "$STATE" | jq -e '.domains.accounts.authorized == true' >/dev/null; then
      break
    fi
    (( $(date +%s) < DEADLINE )) || die "timed out waiting for Alice authorization"
    sleep 1
  done
fi

LIFECYCLE="$(portal_get "$PORTAL_URL/api/consent-lifecycle/accounts")"
CONSENT_ID="$(printf '%s' "$LIFECYCLE" | jq -er '.consent_id')"
CONSENT_STATUS="$(printf '%s' "$LIFECYCLE" | jq -er '.consent_status')"
CONSENT_MGR="$(printf '%s' "$LIFECYCLE" | jq -er '.portal_url')"

echo
echo "============================================================"
echo "1. LIVE CONSENT BEFORE REVOCATION"
echo "============================================================"
printf '%s\n' "$LIFECYCLE" | jq .

case "$(printf '%s' "$CONSENT_STATUS" | tr '[:upper:]' '[:lower:]')" in
  authorised|authorized) ;;
  *) die "Accounts consent is not active before the demo: $CONSENT_STATUS" ;;
esac

BEFORE="$(portal_post "$PORTAL_URL/api/consent-lifecycle/accounts/retest")"
BEFORE_HTTP="$(printf '%s' "$BEFORE" | jq -er '.http')"
BEFORE_FP="$(printf '%s' "$BEFORE" | jq -er '.request.token_fingerprint')"

echo
echo "============================================================"
echo "2. EXACT ACCOUNTS CALL BEFORE REVOCATION"
echo "============================================================"
printf '%s\n' "$BEFORE" | jq .

[[ "$BEFORE_HTTP" == "200" ]] || die "expected /accounts to return 200 before revocation, got $BEFORE_HTTP"

"$ROOT/demo/consent-manager-preflight.sh" --quiet

echo
echo "============================================================"
echo "3. REVOKE IN WSO2 CONSENT MANAGER"
echo "============================================================"
echo "Consent ID: $CONSENT_ID"
echo "Portal:     $CONSENT_MGR"
echo
echo "[ACTION] In Consent Manager:"
echo "         1. Sign in as Alice."
echo "         2. Find consent $CONSENT_ID."
echo "         3. Show its current details/status."
echo "         4. Click Stop Sharing / Revoke and confirm."
echo
echo "[ACTION] The script will detect the live status change automatically."

open "$CONSENT_MGR"

DEADLINE=$(( $(date +%s) + 600 ))
while :; do
  LIFECYCLE="$(portal_get "$PORTAL_URL/api/consent-lifecycle/accounts")"
  CONSENT_STATUS="$(printf '%s' "$LIFECYCLE" | jq -r '.consent_status // empty')"
  NORMALIZED="$(printf '%s' "$CONSENT_STATUS" | tr '[:upper:]' '[:lower:]')"

  case "$NORMALIZED" in
    authorised|authorized|"")
      ;;
    *)
      break
      ;;
  esac

  (( $(date +%s) < DEADLINE )) || die "timed out waiting for consent revocation"
  sleep 1
done

echo
echo "============================================================"
echo "4. LIVE CONSENT AFTER REVOCATION"
echo "============================================================"
printf '%s\n' "$LIFECYCLE" | jq .

AFTER="$(portal_post "$PORTAL_URL/api/consent-lifecycle/accounts/retest")"
AFTER_HTTP="$(printf '%s' "$AFTER" | jq -er '.http')"
AFTER_FP="$(printf '%s' "$AFTER" | jq -er '.request.token_fingerprint')"

echo
echo "============================================================"
echo "5. EXACT SAME ACCOUNTS CALL AFTER REVOCATION"
echo "============================================================"
printf '%s\n' "$AFTER" | jq .

[[ "$BEFORE_FP" == "$AFTER_FP" ]] \
  || die "access token changed; lifecycle proof is invalid"

[[ "$AFTER_HTTP" != "200" ]] \
  || die "/accounts still returned 200 after consent revocation"

printf '%s' "$AFTER" | jq -e '.rejected == true' >/dev/null \
  || die "post-revocation request was not marked rejected"

echo
echo "[OK] CONSENT LIFECYCLE DEMO PASSED"
echo "[OK] /accounts before revoke: HTTP $BEFORE_HTTP"
echo "[OK] /accounts after revoke:  HTTP $AFTER_HTTP"
echo "[OK] same access token fingerprint: $BEFORE_FP"
echo "[OK] live consent status after revoke: $CONSENT_STATUS"
echo
echo "Consent is live policy state: the same OAuth access token and the same mTLS"
echo "client were presented to the same /accounts resource; only consent state changed."
