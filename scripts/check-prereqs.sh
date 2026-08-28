#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
need docker; need openssl; need curl; need jq; need awk; need sed

docker compose version >/dev/null 2>&1 || fatal "Docker Compose v2 is required"
if [[ "${ALLOW_UNSUPPORTED_WSO2_COMBINATION:-false}" != "true" ]]; then
  if [[ "${APIM_VERSION:-}" == "4.6.0" && "${IS_VERSION:-}" == "7.2.0" && "${FS_ACCELERATOR_VERSION:-}" == "4.0.0" ]]; then
    log "Compatibility gate: APIM 4.6.0 + IS 7.2.0 + FS Accelerator 4.0.0 accepted."
  else
    fatal "APIM ${APIM_VERSION:-4.7.0} + IS ${IS_VERSION:-7.3.0} is newer than the published Accelerator 4.0 compatibility matrix. Set ALLOW_UNSUPPORTED_WSO2_COMBINATION=true only if you intentionally accept this demo compatibility experiment."
  fi
fi
log "Using supported demo baseline: APIM ${APIM_VERSION:-4.6.0} + IS ${IS_VERSION:-7.2.0} + Accelerator ${FS_ACCELERATOR_VERSION:-4.0.0}."
