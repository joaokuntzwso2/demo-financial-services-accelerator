#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

PORTAL_URL="${FINLINK_PORTAL_URL:-https://localhost:9445}"
CA=".state/certs/ca.crt"
STATE_DIR=".state/finlink"
PID_FILE="$STATE_DIR/finlink.pid"
LOG_FILE="$STATE_DIR/finlink.log"
BIN="$STATE_DIR/finlink"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

ACTION="${1:-start}"
NO_OPEN=0
for ARG in "$@"; do
  [[ "$ARG" == "--no-open" ]] && NO_OPEN=1
done

running() {
  [[ -s "$PID_FILE" ]] || return 1
  local PID
  PID="$(cat "$PID_FILE")"
  kill -0 "$PID" 2>/dev/null
}

stop_portal() {
  if running; then
    local PID
    PID="$(cat "$PID_FILE")"
    kill "$PID" 2>/dev/null || true
    for _ in $(seq 1 30); do
      kill -0 "$PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -9 "$PID" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
}

case "$ACTION" in
  stop)
    stop_portal
    echo "[OK] FinLink stopped"
    exit 0
    ;;
  restart)
    stop_portal
    ;;
  status)
    if running; then
      echo "[OK] FinLink running PID $(cat "$PID_FILE")"
      exit 0
    fi
    echo "FinLink is not running"
    exit 1
    ;;
  start|--no-open)
    ;;
  *)
    echo "Usage: ./demo/finlink.sh [start|stop|restart|status] [--no-open]" >&2
    exit 2
    ;;
esac

for FILE in \
  .state/demo-access/demo-access.json \
  .state/certs/tpp.crt \
  .state/certs/tpp.key \
  .state/certs/tpp.kid \
  "$CA"
do
  [[ -s "$FILE" ]] || {
    echo "ERROR: missing $FILE; start/bootstrap the demo first" >&2
    exit 1
  }
done

./scripts/configure-finlink-callback.sh

build_portal() {
  if command -v go >/dev/null 2>&1; then
    (
      cd demo/finlink
      go test ./...
      go build -o "$ROOT/$BIN" .
    )
    return
  fi

  command -v docker >/dev/null 2>&1 || {
    echo "ERROR: either Go or Docker is required" >&2
    exit 1
  }

  docker run --rm     -v "$ROOT/demo/finlink:/src"     -w /src     golang:1.25     go test ./...

  local GOOS_TARGET GOARCH_TARGET
  case "$(uname -s)" in
    Darwin) GOOS_TARGET="darwin" ;;
    Linux) GOOS_TARGET="linux" ;;
    *)
      echo "ERROR: unsupported host OS: $(uname -s)" >&2
      exit 1
      ;;
  esac

  case "$(uname -m)" in
    arm64|aarch64) GOARCH_TARGET="arm64" ;;
    x86_64|amd64) GOARCH_TARGET="amd64" ;;
    *)
      echo "ERROR: unsupported host architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac

  docker run --rm     -e CGO_ENABLED=0     -e GOOS="$GOOS_TARGET"     -e GOARCH="$GOARCH_TARGET"     -v "$ROOT:/src"     -w /src/demo/finlink     golang:1.25     go build -o "/src/$BIN" .

  chmod +x "$BIN"
}

if running; then
  echo "[OK] FinLink already running PID $(cat "$PID_FILE")"
else
  build_portal

  : > "$LOG_FILE"

  FINLINK_NO_OPEN=1 \
    nohup "$BIN" \
    >> "$LOG_FILE" \
    2>&1 &

  PID=$!
  printf '%s\n' "$PID" > "$PID_FILE"
  chmod 600 "$PID_FILE" "$LOG_FILE" 2>/dev/null || true

  READY=0
  for _ in $(seq 1 80); do
    if curl -fsS --cacert "$CA" "$PORTAL_URL/healthz" >/dev/null 2>&1; then
      READY=1
      break
    fi
    if ! kill -0 "$PID" 2>/dev/null; then
      break
    fi
    sleep 0.25
  done

  if [[ "$READY" != "1" ]]; then
    cat "$LOG_FILE" >&2 || true
    echo "ERROR: FinLink did not become ready" >&2
    exit 1
  fi

  echo "[OK] FinLink running PID $PID"
fi

echo "[OK] $PORTAL_URL"

if [[ "$NO_OPEN" == "0" && "$ACTION" != "--no-open" ]]; then
  open "$PORTAL_URL"
fi
