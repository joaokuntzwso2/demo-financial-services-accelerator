#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ -f .env ]] && set -a && source .env && set +a
log(){ printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn(){ printf '\n\033[1;33mWARNING: %s\033[0m\n' "$*"; }
fatal(){ printf '\n\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"; }
retry(){ local n=0 max=${2:-60}; local cmd=$1; until eval "$cmd"; do n=$((n+1)); ((n>=max)) && return 1; sleep 5; done; }
