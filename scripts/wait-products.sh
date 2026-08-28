#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
log "Waiting for Identity Server"
retry "curl -ksSf https://localhost:${IS_HTTPS_PORT:-9446}/oauth2/jwks >/dev/null" 80 || fatal "IS did not become healthy"
log "Waiting for API Manager"
retry "curl -ksSf https://localhost:${APIM_HTTPS_PORT:-9443}/services/Version >/dev/null || curl -ksSf https://localhost:${APIM_HTTPS_PORT:-9443}/publisher >/dev/null" 100 || fatal "APIM did not become healthy"
