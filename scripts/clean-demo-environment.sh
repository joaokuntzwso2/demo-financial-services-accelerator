#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo
echo "==> Ensuring a clean WSO2 Open Banking demo environment"

# First let Compose remove everything it owns for the current project,
# including the MySQL volume.
docker compose down \
  -v \
  --remove-orphans \
  >/dev/null 2>&1 || true

# The demo historically uses fixed container names. Remove leftovers from
# another checkout or an interrupted previous run.
DEMO_CONTAINERS=(
  wso2-ob-apim
  wso2-ob-is
  wso2-ob-mysql
  wso2-ob-bank-backend
  wso2-ob-bootstrap
)

for container in "${DEMO_CONTAINERS[@]}"; do
  if docker container inspect "$container" >/dev/null 2>&1; then
    echo "    Removing stale container: $container"
    docker rm -f "$container" >/dev/null
  fi
done

# Remove the fixed demo network if it survived an interrupted Compose run.
if docker network inspect wso2-ob-demo-net >/dev/null 2>&1; then
  echo "    Removing stale network: wso2-ob-demo-net"
  docker network rm wso2-ob-demo-net >/dev/null 2>&1 || true
fi

# Clean Compose volumes belonging specifically to this demo.
#
# This also protects against previous acceptance-test project names such as
# wso2-ob-acceptance while avoiding unrelated Docker volumes.
while IFS= read -r volume; do
  [[ -n "$volume" ]] || continue

  project="$(
    docker volume inspect \
      -f '{{if .Labels}}{{index .Labels "com.docker.compose.project"}}{{end}}' \
      "$volume" \
      2>/dev/null || true
  )"

  case "$project" in
    wso2-openbanking-e2e|wso2-ob-*)
      echo "    Removing stale demo volume: $volume"
      docker volume rm "$volume" >/dev/null 2>&1 || true
      ;;
  esac
done < <(docker volume ls -q)

# Backward-compatible cleanup for the repository's historical default volume.
if docker volume inspect \
    wso2-openbanking-e2e_mysql_data \
    >/dev/null 2>&1; then
  echo "    Removing stale demo volume: wso2-openbanking-e2e_mysql_data"
  docker volume rm \
    wso2-openbanking-e2e_mysql_data \
    >/dev/null
fi

# All generated certificates, bootstrap IDs, policies and credentials belong
# to the runtime instance and must match its fresh databases.
if [[ -e .state ]]; then
  echo "    Removing generated runtime state: .state/"
  rm -rf .state
fi

echo
echo "==> Verifying clean environment"

FAILED=0

for container in "${DEMO_CONTAINERS[@]}"; do
  if docker container inspect "$container" >/dev/null 2>&1; then
    echo "    [FAIL] container still exists: $container" >&2
    FAILED=1
  fi
done

if docker network inspect wso2-ob-demo-net >/dev/null 2>&1; then
  echo "    [FAIL] demo network still exists" >&2
  FAILED=1
fi

if docker volume inspect \
    wso2-openbanking-e2e_mysql_data \
    >/dev/null 2>&1; then
  echo "    [FAIL] demo MySQL volume still exists" >&2
  FAILED=1
fi

if [[ -e .state ]]; then
  echo "    [FAIL] generated .state still exists" >&2
  FAILED=1
fi

if (( FAILED != 0 )); then
  echo
  echo "FATAL: Could not establish a clean demo environment." >&2
  exit 1
fi

echo "    [OK] no previous demo containers"
echo "    [OK] no previous demo network"
echo "    [OK] no previous demo database volume"
echo "    [OK] no previous generated .state"
echo
echo "==> Clean environment confirmed"
