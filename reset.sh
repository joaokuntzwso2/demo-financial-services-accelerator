#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"; cd "$ROOT"
docker compose --profile tools down -v --remove-orphans || true
rm -rf .state
printf 'Local DB volume, generated certificates and bootstrap state removed. dist/ and .cache/ retained.\n'
