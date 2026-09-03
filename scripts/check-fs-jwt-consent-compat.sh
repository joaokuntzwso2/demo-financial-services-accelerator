#!/usr/bin/env bash

set -Eeuo pipefail

IS_CONTAINER="${IS_CONTAINER:-wso2-ob-is}"

BUNDLE="/home/wso2carbon/wso2is-7.2.0/repository/components/dropins/finlink-fs-jwt-consent-compat-1.0.0.jar"

echo "==> Financial Services JWT consent compatibility"

docker exec "$IS_CONTAINER" sh -lc "
  test -f '$BUNDLE'
  jar tf '$BUNDLE' |
    grep -q 'com/acme/finlink/fscompat/ConsentJWTAccessTokenClaimProvider.class'
"

echo "[OK] JWT consent compatibility bundle installed"

REGISTRATION="$(
  docker logs "$IS_CONTAINER" 2>&1 |
    grep -F \
      '[FINLINK-FS-COMPAT] JWT consent claim provider registered' |
    tail -1 ||
    true
)"

if [[ -z "$REGISTRATION" ]]; then
  echo "[ERROR] JWT consent claim provider registration not found"
  exit 1
fi

echo "[OK] JWT consent claim provider registered"
