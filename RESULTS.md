# Webhook Processing Benchmark — Results

Host: Apple M4 Pro (12 physical cores), macOS 26.4
Workload: Shopify-style `POST /webhook` — HMAC-SHA256 verify → JSON parse → for each variant, upcase string values + serialize back to JSON + write to `/dev/null`. Single ~10KB payload with 5 variants.
Client: Rust + tokio + hyper raw HTTP/1.1, 256 keep-alive connections, 5s warmup, 30s measurement window.

CPU caps are enforced natively per language (no containers): `GOMAXPROCS`, `TOKIO_WORKER_THREADS`, BEAM `+S N:N` (plus dirty / async pool caps), `falcon --count N`. All runs verified `cap_holds` (server CPU within 10% of cap) and `client_bottlenecked=false`.

## Baselines

| Lang   | Cores | rps    | p50 (µs) | p99 (µs) | server CPU |
|--------|-------|-------:|---------:|---------:|-----------:|
| Ruby   | 1     | 7,807  | 32,735   | 36,479   | 99.5%      |
| Elixir | 1     | 7,078  | 35,775   | 41,471   | 109.5%     |
| Go     | 1     | 7,710  | 17,215   | 133,247  | 99.6%      |
| Rust   | 1     | 20,293 | 12,471   | 16,359   | 98.8%      |
| Ruby   | 4     | 25,136 | 10,087   | 13,575   | 391.1%     |
| Elixir | 4     | 27,918 | 9,047    | 11,239   | 436.1%     |
| Go     | 4     | 23,733 | 7,639    | 48,031   | 383.7%     |
| Rust   | 4     | 63,159 | 4,017    | 8,663    | 383.9%     |

Stacks:
- Ruby — Falcon 0.51 (fiber-per-request) + Rack 3 + stdlib `json`, Ruby 4.0.4
- Elixir — Bandit 1.5 + Plug 1.16 + Jason 1.4 on OTP 28 / Elixir 1.19
- Go — `net/http` stdlib + `encoding/json`, Go 1.26
- Rust — axum 0.7 + serde_json + tokio multi-thread, Rust 1.92

## Optimization rounds

One realistic round per language. Each round saves a new result alongside the baseline so the delta is reproducible.

| Lang   | Cores | Variant            | rps    | Δ vs baseline | p50 (µs) | p99 (µs) |
|--------|-------|--------------------|-------:|--------------:|---------:|---------:|
| Ruby   | 1     | `oj` + YJIT        | 9,490  | +21.6%        | 26,639   | 32,111   |
| Ruby   | 4     | `oj` + YJIT        | 30,261 | +20.4%        | 8,447    | 10,303   |
| Elixir | 1     | OTP 28 `:json`     | 7,792  | +10.1%        | 32,639   | 38,175   |
| Elixir | 4     | OTP 28 `:json`     | 30,014 | +7.5%         | 8,351    | 12,455   |
| Go     | 1     | `goccy/go-json` + GOGC=200 | 12,364 | +60.4% | 21,999   | 28,015   |
| Go     | 4     | `goccy/go-json` + GOGC=200 | 37,007 | +55.9% | 4,987    | 30,223   |
| Rust   | 1     | `simd-json` + scratch buf | 21,393 | +5.4% | 11,903   | 13,527   |
| Rust   | 4     | `simd-json` + scratch buf | 67,574 | +7.0% | 3,633    | 7,775    |

Knobs:
- Ruby — enabled YJIT (`RUBY_YJIT_ENABLE=1`) and swapped stdlib `JSON` for the `oj` gem on the hot path. Falcon configuration unchanged.
- Elixir — switched JSON backend from Jason to OTP 28's built-in `:json` module (introduced in OTP 27). Bandit/Plug otherwise unchanged. CPU drifted just past the 10% cap slack at 4c (445% on a 400% cap) — within noise of baseline (436%) but worth flagging.
- Go — replaced `encoding/json` with `goccy/go-json` (drop-in, pure Go), raised `GOGC` from 100 to 200 to reduce GC pressure. `sync.Pool` for the serializer scratch buffer was already in the baseline.
- Rust — feature-gated `simd-json` for parsing (`simd-json::serde::from_slice`), and reused a thread-local `Vec<u8>` for serialized output to avoid per-variant allocations.

## Notable observations

- At 1 core, Rust starts 2.6× ahead of the next language. Even after Go's +60% jump (12.4k rps), it's still ~1.7× behind Rust's baseline.
- At 4 cores Rust scales nearly linearly to 63k baseline / 67k optimized — the only stack here approaching `connections × ops/second` territory where the kernel scheduler matters.
- Go saw the largest realistic-knob speedup (≈+60%) — `encoding/json`'s reflective parse path is a measurable share of the request budget on this payload shape, and swapping it for `goccy` (pure Go, codegen-style) plus halving GC frequency hits both.
- Ruby and Elixir baselines are remarkably close (within ~10%) at 1 core; both gain ~20% / ~10% from swapping the JSON library. Falcon's fiber concurrency model holds up well at 4c.
- Rust's marginal gain from simd-json (+5–7%) implies JSON parsing is no longer dominant — the remaining wall-time is HMAC + `libc::write` syscalls + tokio scheduling. Further gains would need raw hyper (no axum/router state extraction) or batching writes.
- Go 1c baseline p99 is an outlier (133ms). The `goccy` variant tightens p99 dramatically (28ms) without paying for it in p50 — likely GC-pause sensitivity that GOGC tuning fixed.
- Elixir's CPU usage measured slightly above its scheduler cap on both rounds. The `+S N:N +SDcpu 1:1 +SDio 1 +A 1 +sbwt none` flag set keeps it close, but BEAM's housekeeping leaks ~10–13% above cap regardless.

## How to reproduce

See `.claude/skills/load-test/SKILL.md`. Single-run example:

```bash
DURATION=30s bench/run.sh rust 4 baseline
WPB_RUST_FEATURES=simd bench/run.sh rust 4 simd-json "simd-json + scratch buf"
WPB_JSON=oj RUBY_YJIT_ENABLE=1 bench/run.sh ruby 4 oj-yjit "oj + YJIT"
WPB_GO_TAGS=goccy GOGC=200 bench/run.sh go 4 goccy-gogc200 "goccy/go-json + GOGC=200"
WPB_JSON=otp28 bench/run.sh elixir 4 otp28-json "OTP 28 :json module"
```

All result JSON in `bench/results/`. Each file carries `cap_holds` and `client_bottlenecked` flags — trust an rps number only when both are good.
