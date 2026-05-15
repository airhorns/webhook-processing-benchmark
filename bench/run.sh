#!/usr/bin/env bash
# Bench harness: boot a server with a worker-count cap, run the client, capture stats.
#
# Usage:   bench/run.sh <lang> <cores> <label> [extra notes...]
# Example: bench/run.sh go 4 baseline
#          bench/run.sh ruby 1 oj-json
#
# Outputs:
#   bench/results/<lang>-<cores>c-<label>.json   (machine-readable summary)
#   bench/results/<lang>-<cores>c-<label>.log    (server stdout/stderr)

set -euo pipefail

LANG_="${1:-}"
CORES="${2:-}"
LABEL="${3:-baseline}"
shift 3 2>/dev/null || true
NOTES="${*:-}"

if [[ -z "$LANG_" || -z "$CORES" ]]; then
  echo "usage: bench/run.sh <lang:ruby|elixir|go|rust> <cores:1|4> <label> [notes]" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS_DIR="$REPO_ROOT/bench/results"
mkdir -p "$RESULTS_DIR"

PORT="${PORT:-18080}"
DURATION="${DURATION:-30s}"
WARMUP="${WARMUP:-5s}"
CONNECTIONS="${CONNECTIONS:-256}"
PAYLOAD="$REPO_ROOT/shared/payload.json"
SECRET="$REPO_ROOT/shared/secret.txt"

RESULT_FILE="$RESULTS_DIR/${LANG_}-${CORES}c-${LABEL}.json"
LOG_FILE="$RESULTS_DIR/${LANG_}-${CORES}c-${LABEL}.log"

# ---- build steps (run before launch, output goes to stderr) -----------------
build_server() {
  case "$LANG_" in
    go)
      if [[ -n "${WPB_GO_TAGS:-}" ]]; then
        (cd "$REPO_ROOT/servers/go" && go build -tags "$WPB_GO_TAGS" -o server .) 1>&2
      else
        (cd "$REPO_ROOT/servers/go" && go build -o server .) 1>&2
      fi
      ;;
    rust)
      if [[ -n "${WPB_RUST_FEATURES:-}" ]]; then
        (cd "$REPO_ROOT/servers/rust" && cargo build --release --features "$WPB_RUST_FEATURES" --quiet) 1>&2
      else
        (cd "$REPO_ROOT/servers/rust" && cargo build --release --quiet) 1>&2
      fi
      ;;
    elixir)
      (cd "$REPO_ROOT/servers/elixir" \
        && MIX_ENV=prod mix deps.get --quiet \
        && MIX_ENV=prod mix compile --quiet) 1>&2
      ;;
    ruby)
      (cd "$REPO_ROOT/servers/ruby" \
        && bundle config set --local path 'vendor/bundle' >/dev/null \
        && bundle install --quiet) 1>&2
      ;;
    *)
      echo "unknown lang: $LANG_" >&2; exit 2;;
  esac
}

# ---- launcher per language (must echo only the PID to stdout) ---------------
start_server() {
  case "$LANG_" in
    go)
      cd "$REPO_ROOT/servers/go"
      env GOMAXPROCS="$CORES" GOGC="${GOGC:-100}" PORT="$PORT" HMAC_SECRET_FILE="$SECRET" \
        ./server > "$LOG_FILE" 2>&1 &
      ;;
    rust)
      cd "$REPO_ROOT/servers/rust"
      env TOKIO_WORKER_THREADS="$CORES" PORT="$PORT" HMAC_SECRET_FILE="$SECRET" \
        ./target/release/wpb-rust-server > "$LOG_FILE" 2>&1 &
      ;;
    elixir)
      cd "$REPO_ROOT/servers/elixir"
      # +S regular schedulers (capped to CORES).
      # +SDcpu 1:1 minimum dirty CPU schedulers (we don't use dirty NIFs).
      # +SDio 1 minimum dirty I/O schedulers (file.write in :raw mode stays on caller).
      # +A 1 small async thread pool.
      # +sbwt none + relatives disable busy-wait (otherwise BEAM spins CPU when idle).
      env PORT="$PORT" HMAC_SECRET_FILE="$SECRET" \
        elixir --erl "+S ${CORES}:${CORES} +SDcpu 1:1 +SDio 1 +A 1 +sbwt none +sbwtdcpu none +sbwtdio none" \
        -S mix run --no-halt > "$LOG_FILE" 2>&1 &
      ;;
    ruby)
      cd "$REPO_ROOT/servers/ruby"
      env PORT="$PORT" HMAC_SECRET_FILE="$SECRET" \
        bundle exec falcon serve --bind "http://127.0.0.1:$PORT" --count "$CORES" \
        --config config.ru > "$LOG_FILE" 2>&1 &
      ;;
    *)
      echo "unknown lang: $LANG_" >&2; exit 2;;
  esac
  echo $!
}

build_server
SERVER_PID=$(start_server)
echo "[bench] $LANG_ ($CORES core, label=$LABEL) pid=$SERVER_PID port=$PORT" >&2

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    # Kill the process group so Falcon/Mix children die too.
    pkill -P "$SERVER_PID" 2>/dev/null || true
    kill "$SERVER_PID" 2>/dev/null || true
    sleep 0.3
    kill -9 "$SERVER_PID" 2>/dev/null || true
    pkill -9 -P "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "${SAMPLER_PID:-}" ]] && kill -0 "$SAMPLER_PID" 2>/dev/null; then
    kill "$SAMPLER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# Wait for port to open.
WAITED=0
until nc -z 127.0.0.1 "$PORT" 2>/dev/null; do
  sleep 0.2
  WAITED=$((WAITED + 1))
  if [[ $WAITED -gt 100 ]]; then
    echo "[bench] server did not come up on $PORT within 20s" >&2
    tail -30 "$LOG_FILE" >&2 || true
    exit 1
  fi
done
echo "[bench] server up after ~$((WAITED * 200))ms" >&2

# Single smoke request to confirm 200 before benching.
HMAC=$(openssl dgst -sha256 -hmac "$(cat "$SECRET")" -binary "$PAYLOAD" | base64)
SMOKE_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -H "X-Shopify-Hmac-Sha256: $HMAC" \
  --data-binary "@$PAYLOAD" \
  "http://127.0.0.1:$PORT/webhook" || echo "000")
if [[ "$SMOKE_STATUS" != "200" ]]; then
  echo "[bench] smoke test failed (status=$SMOKE_STATUS); aborting." >&2
  tail -40 "$LOG_FILE" >&2 || true
  exit 1
fi
echo "[bench] smoke ok (200), starting client..." >&2

# CPU sampler — psutil-based, polls server PID + descendants every 250ms.
CPU_SAMPLES="$RESULTS_DIR/.${LANG_}-${CORES}c-${LABEL}.cpu"
"$REPO_ROOT/bench/cpu_sampler.py" "$SERVER_PID" "$CPU_SAMPLES" 0.25 &
SAMPLER_PID=$!

# Run client and capture summary JSON.
CLIENT_BIN="$REPO_ROOT/client/target/release/wpb-client"
[[ -x "$CLIENT_BIN" ]] || (cd "$REPO_ROOT/client" && cargo build --release --quiet)

CLIENT_JSON=$("$CLIENT_BIN" \
  --url "http://127.0.0.1:$PORT/webhook" \
  --connections "$CONNECTIONS" \
  --warmup "$WARMUP" \
  --duration "$DURATION" \
  --payload "$PAYLOAD" \
  --secret-file "$SECRET" \
  --json 2>>"$LOG_FILE")

kill "$SAMPLER_PID" 2>/dev/null || true
wait "$SAMPLER_PID" 2>/dev/null || true

# Compute server CPU avg/max from samples. File format: "ts_ms cpu_pct", header on row 1.
# Skip first 2 data rows (first sample is always 0 right after sampler start; warmup also bleeds).
read CPU_AVG CPU_MAX SAMPLES <<<"$(
  awk 'NR>3 {if ($2+0 > max) max = $2+0; sum += $2+0; n++}
    END {if (n==0) print "0 0 0"; else printf "%.2f %.2f %d", sum/n, max, n}' "$CPU_SAMPLES"
)"
rm -f "$CPU_SAMPLES"

# Build the final result JSON by merging client summary + server CPU + meta.
python3 - "$RESULT_FILE" <<PY
import json, sys, os, time
result_file = sys.argv[1]
client = json.loads('''$CLIENT_JSON''')
out = {
  "lang": "$LANG_",
  "cores": $CORES,
  "label": "$LABEL",
  "notes": "$NOTES",
  "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
  "rps": client["rps"],
  "ok": client["ok"],
  "errors": client["errors"],
  "p50_us": client["p50_us"],
  "p90_us": client["p90_us"],
  "p99_us": client["p99_us"],
  "p999_us": client["p999_us"],
  "max_us": client["max_us"],
  "duration_s": client["duration_s"],
  "connections": client["connections"],
  "server_cpu_avg_pct": $CPU_AVG,
  "server_cpu_max_pct": $CPU_MAX,
  "server_cpu_samples": $SAMPLES,
  "server_cpu_cap_pct": $CORES * 100,
  "client_cpu_pct_of_one_core": client["client_cpu_pct_of_one_core"],
}
out["cap_holds"] = bool(out["server_cpu_avg_pct"] <= out["server_cpu_cap_pct"] * 1.10)
out["client_bottlenecked"] = bool(out["client_cpu_pct_of_one_core"] > 85 * (os.cpu_count() or 1))
with open(result_file, "w") as f:
  json.dump(out, f, indent=2)
print(json.dumps(out, indent=2))
PY

echo "[bench] wrote $RESULT_FILE" >&2
