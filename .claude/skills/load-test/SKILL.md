---
name: load-test
description: Build, start, bench, or stop any of the four webhook server implementations (Ruby/Falcon, Elixir/Bandit, Go/net-http, Rust/axum) and run the Rust load generator against them. Use when the user mentions "load test", "benchmark", "run the bench", "compare servers", or names a specific language (ruby/elixir/go/rust) in a perf-testing context inside this repo.
---

# Webhook Processing Benchmark — load-test skill

This skill drives the four-language benchmark in this repo. All commands assume the working directory is the repo root.

## Layout

- `client/` — Rust+hyper load generator (binary: `client/target/release/wpb-client`)
- `servers/{ruby,elixir,go,rust}/` — one implementation per language
- `shared/payload.json` + `shared/secret.txt` — fixtures used by all servers and the client
- `bench/run.sh` — orchestrates one bench run (start server → smoke → load → record)
- `bench/results/` — per-run JSON (and a `.log` with the server's stdout/stderr)

## Build everything

```bash
# Client (do this first — nothing else is measurable without it)
(cd client && cargo build --release)

# Servers
(cd servers/go && go build -o server .)
(cd servers/rust && cargo build --release)
(cd servers/elixir && MIX_ENV=prod mix deps.get && MIX_ENV=prod mix compile)
(cd servers/ruby && bundle config set --local path 'vendor/bundle' && bundle install)
```

`bench/run.sh` builds the server it's about to run automatically — explicit builds above are only required if you want to validate the toolchains separately.

## Run one bench

```bash
bench/run.sh <lang> <cores> <label> [notes...]
```

- `<lang>` ∈ {go, rust, elixir, ruby}
- `<cores>` ∈ {1, 4} (other values work but the CPU cap is enforced by worker-count config)
- `<label>` — arbitrary string, ends up in the result filename (`bench/results/<lang>-<cores>c-<label>.json`)
- `<notes>` — free-text, lands in the result JSON

Override knobs via env:

- `DURATION=30s` — measurement window (default 30s)
- `WARMUP=5s` — warmup window before measurement starts (default 5s)
- `CONNECTIONS=256` — concurrent keep-alive connections from the client (default 256)
- `PORT=18080` — server port

Example:

```bash
DURATION=30s CONNECTIONS=512 bench/run.sh rust 4 baseline "axum + serde_json"
```

## Run the full baseline sweep

```bash
for lang in go rust elixir ruby; do
  for cores in 1 4; do
    bench/run.sh "$lang" "$cores" baseline
  done
done
```

This produces 8 result files in `bench/results/`. Each result includes throughput, p50/p90/p99/p999 latency, server CPU avg/max, and bottleneck flags.

## Interpreting results

Each result JSON includes:

- `rps` — successful requests per second during the measurement window
- `p50_us`, `p99_us` — request latency percentiles in microseconds
- `server_cpu_avg_pct` — average CPU% across server + descendants (one busy core = 100%)
- `server_cpu_cap_pct` — what the cap should be (`cores * 100`)
- `cap_holds` — true if `server_cpu_avg_pct ≤ cap * 1.10`
- `client_cpu_pct_of_one_core` — client's own CPU usage. If close to `100 * num_cpus`, the client is the bottleneck; bump `CONNECTIONS` and rerun.

**Always check `cap_holds` and `client_bottlenecked` before trusting an rps number.**

## Per-language worker-count caps

| Language | Cap mechanism                                                  |
|----------|----------------------------------------------------------------|
| Go       | `GOMAXPROCS=N` env var                                         |
| Rust     | `TOKIO_WORKER_THREADS=N` env var (read by `Builder::worker_threads`) |
| Elixir   | `--erl "+S N:N +SDcpu 1:1 +SDio 1 +A 1 +sbwt none +sbwtdcpu none +sbwtdio none"` |
| Ruby     | `falcon serve --count N` (one fork per N, each fiber-based)    |

Elixir requires explicitly capping dirty schedulers and async pool, otherwise BEAM exceeds the regular scheduler count.

## Start a server by hand (without `run.sh`)

For interactive debugging — every server reads `PORT` and `HMAC_SECRET_FILE`:

```bash
# Go (4 cores)
(cd servers/go && GOMAXPROCS=4 PORT=18080 HMAC_SECRET_FILE=../../shared/secret.txt ./server)

# Rust (4 cores)
(cd servers/rust && TOKIO_WORKER_THREADS=4 PORT=18080 HMAC_SECRET_FILE=../../shared/secret.txt ./target/release/wpb-rust-server)

# Elixir (4 cores)
(cd servers/elixir && PORT=18080 HMAC_SECRET_FILE=../../shared/secret.txt \
  elixir --erl "+S 4:4 +SDcpu 1:1 +SDio 1 +A 1 +sbwt none +sbwtdcpu none +sbwtdio none" -S mix run --no-halt)

# Ruby (4 cores)
(cd servers/ruby && PORT=18080 HMAC_SECRET_FILE=../../shared/secret.txt \
  bundle exec falcon serve --bind http://127.0.0.1:18080 --count 4 --config config.ru)
```

## Run the client by hand

```bash
client/target/release/wpb-client \
  --url http://127.0.0.1:18080/webhook \
  --connections 256 \
  --warmup 5s \
  --duration 30s \
  --payload shared/payload.json \
  --secret-file shared/secret.txt \
  --json
```

## Cleaning up

```bash
# Kill anything listening on the bench port
lsof -i :18080 -t 2>/dev/null | xargs -r kill -9
# Plus any stray Falcon forks
pkill -9 -f falcon 2>/dev/null
```
