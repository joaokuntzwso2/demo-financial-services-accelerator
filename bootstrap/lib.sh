#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fatal(){ printf '\n\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }
retry(){ local n=0 max=${RETRY_MAX:-40}; until "$@"; do n=$((n+1)); ((n>=max)) && return 1; sleep 5; done; }
curlj(){ curl -ksS --fail-with-body "$@"; }
json_field(){ jq -er "$1"; }
