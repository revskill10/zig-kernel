#!/usr/bin/env bash
# Built-process HTTP probes for the fail-closed zig-sandbox bootstrap.
# zig-sandbox is linux-musl. Run this on Linux, WSL, or an isolated container.
# Does not use Git. All caches stay under the repository .tmp directory.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export TMPDIR="${TMPDIR:-$ROOT/.tmp/sandbox-implementation}"
export TEMP="$TMPDIR"
export TMP="$TMPDIR"
mkdir -p "$TMPDIR" \
  "$ROOT/.tmp/sandbox-implementation/zig-cache" \
  "$ROOT/.tmp/zig-global-cache" \
  "$ROOT/.tmp/sandbox-implementation/build"

if [ "$(uname -s 2>/dev/null)" != "Linux" ]; then
  echo "sandbox-probe.sh requires Linux (WSL or container); zig-sandbox is linux-musl" >&2
  exit 2
fi

ZIG="${ZIG:-zig}"
PREFIX="$ROOT/.tmp/sandbox-implementation/build"
BIN="$PREFIX/bin/zig-sandbox"
LOG="$ROOT/.tmp/sandbox-implementation/sandbox-probe.log"
RESULT="$ROOT/.tmp/sandbox-implementation/sandbox-probe-result.txt"
: >"$LOG"
: >"$RESULT"

if [ -n "${SANDBOX_PROBE_BIN:-}" ]; then
  BIN="$SANDBOX_PROBE_BIN"
else
  echo "building zig-sandbox into $PREFIX" | tee -a "$LOG"
  (
    cd "$ROOT" && "$ZIG" build sandbox-api -Doptimize=ReleaseSafe \
      --cache-dir "$ROOT/.tmp/sandbox-implementation/zig-cache" \
      --global-cache-dir "$ROOT/.tmp/zig-global-cache" \
      --prefix "$PREFIX"
  ) >>"$LOG" 2>&1 || {
    echo "BUILD_FAILED" | tee -a "$RESULT"
    exit 1
  }
fi

if [ ! -x "$BIN" ]; then
  echo "missing $BIN" | tee -a "$RESULT"
  exit 1
fi

DIGEST="$(sha256sum "$BIN" | awk '{print $1}')"
echo "binary_sha256=$DIGEST" | tee -a "$RESULT"
if [ -n "${SANDBOX_PROBE_SHA256:-}" ] && [ "$DIGEST" != "$SANDBOX_PROBE_SHA256" ]; then
  echo "DIGEST_MISMATCH want=$SANDBOX_PROBE_SHA256 got=$DIGEST" | tee -a "$RESULT"
  exit 1
fi

HOST="127.0.0.1"
PORT="${SANDBOX_PROBE_PORT:-18080}"
if curl -sS -m 1 -o /dev/null "http://$HOST:$PORT/healthz" >/dev/null 2>&1; then
  echo "PORT_OCCUPIED $HOST:$PORT" | tee -a "$RESULT"
  exit 1
fi

"$BIN" serve --host="$HOST" --port="$PORT" >>"$LOG" 2>&1 &
PID=$!
cleanup() {
  kill "$PID" >/dev/null 2>&1 || true
  wait "$PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ok=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! kill -0 "$PID" >/dev/null 2>&1; then
    echo "PROCESS_DIED pid=$PID" | tee -a "$RESULT"
    exit 1
  fi
  if curl -sS -m 1 -o /dev/null -w "%{http_code}" "http://$HOST:$PORT/healthz" | grep -q 200; then
    ok=1
    break
  fi
  sleep 0.2
done
if [ "$ok" != 1 ]; then
  echo "LISTEN_FAILED pid=$PID" | tee -a "$RESULT"
  exit 1
fi
if ! kill -0 "$PID" >/dev/null 2>&1; then
  echo "PROCESS_DIED_AFTER_READY pid=$PID" | tee -a "$RESULT"
  exit 1
fi
if ! grep -q "listening on http://$HOST:$PORT" "$LOG"; then
  echo "LISTEN_LOG_MISSING pid=$PID port=$PORT" | tee -a "$RESULT"
  exit 1
fi
echo "listener_pid=$PID" | tee -a "$RESULT"

fail=0
req() {
  local name="$1" want="$2" needle="$3"
  shift 3
  local body code
  body="$(mktemp "$TMPDIR/probe.XXXXXX")"
  code="$(curl -sS -m 5 -o "$body" -w "%{http_code}" "$@" || true)"
  if [ "$code" != "$want" ]; then
    echo "FAIL $name status $code want $want" | tee -a "$RESULT"
    fail=1
    return
  fi
  if [ -n "$needle" ] && ! grep -q -F "$needle" "$body"; then
    echo "FAIL $name missing $needle" | tee -a "$RESULT"
    fail=1
    return
  fi
  echo "PASS $name $code" | tee -a "$RESULT"
}

req health 200 '"status":"ok"' "http://$HOST:$PORT/healthz"
req ready 503 execution_unavailable "http://$HOST:$PORT/readyz"
req caps 200 '"execution":false' "http://$HOST:$PORT/v1/capabilities"
req create 501 execution_unavailable -X POST -H "Content-Type: application/json" --data '{"image":"example"}' "http://$HOST:$PORT/v1/sandboxes"
req query 501 execution_unavailable -X POST "http://$HOST:$PORT/v1/sandboxes?trace=1"
req processes 501 execution_unavailable -X POST "http://$HOST:$PORT/v1/sandboxes/s1/processes"
req exports 404 not_found "http://$HOST:$PORT/v1/exports"
req operations 404 not_found "http://$HOST:$PORT/v1/operations/op_1"
req method 405 method_not_allowed -X POST "http://$HOST:$PORT/healthz"
req oversize 413 payload_too_large -X POST -H "Content-Length: 1048577" "http://$HOST:$PORT/v1/sandboxes"

head_body="$(mktemp "$TMPDIR/probe.XXXXXX")"
head_code="$(curl -sS -m 5 -o "$head_body" -w "%{http_code}" -X HEAD "http://$HOST:$PORT/v1/capabilities" || true)"
if [ "$head_code" != "200" ]; then
  echo "FAIL head status $head_code" | tee -a "$RESULT"
  fail=1
elif [ -s "$head_body" ]; then
  echo "FAIL head body not empty" | tee -a "$RESULT"
  fail=1
else
  echo "PASS head 200 empty-body" | tee -a "$RESULT"
fi

# Nested diagnostic envelope, not canonical request_id/retryable.
caps_body="$(curl -sS -m 5 "http://$HOST:$PORT/v1/capabilities")"
case "$caps_body" in
  *"\"execution\":false"*) echo "PASS capabilities_execution_false" | tee -a "$RESULT" ;;
  *) echo "FAIL capabilities_execution_false" | tee -a "$RESULT"; fail=1 ;;
esac
err_body="$(curl -sS -m 5 -X POST "http://$HOST:$PORT/v1/sandboxes")"
case "$err_body" in
  *'"error":{"code":"execution_unavailable"'*) echo "PASS diagnostic_nested_envelope" | tee -a "$RESULT" ;;
  *) echo "FAIL diagnostic_nested_envelope $err_body" | tee -a "$RESULT"; fail=1 ;;
esac
case "$err_body" in
  *request_id*) echo "FAIL diagnostic_must_not_use_canonical_envelope" | tee -a "$RESULT"; fail=1 ;;
  *) echo "PASS diagnostic_not_canonical" | tee -a "$RESULT" ;;
esac

if [ "$fail" = 0 ]; then
  echo "PROBE_OK binary_sha256=$DIGEST" | tee -a "$RESULT"
  exit 0
fi
echo "PROBE_FAILED binary_sha256=$DIGEST" | tee -a "$RESULT"
exit 1
