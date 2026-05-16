# Webhook Processing Benchmark — x86_64 Linux Results

Host: AMD EPYC 4484PX 12-Core Processor (12 physical cores / 24 logical CPUs), AuthenticAMD, 93Gi RAM, Debian GNU/Linux 12 (bookworm), kernel 6.1.0-43-amd64
Frequency: min 3000.0000 MHz, max 5660.2700 MHz as reported by `lscpu`.
Workload: Shopify-style `POST /webhook` — HMAC-SHA256 verify → JSON parse → for each variant, upcase string values + serialize back to JSON + write to `/dev/null`. Single ~10KB payload with 5 variants.
Client: Rust + tokio + hyper raw HTTP/1.1, 256 keep-alive connections, 5s warmup, 30s measurement window.

Note: the prompt called this an Intel run, but the machine reports `AuthenticAMD` / AMD EPYC. Treat these as x86_64 Linux results rather than Intel-branded silicon results.

## Hardware report

| Item | Value |
|------|-------|
| CPU model | AMD EPYC 4484PX 12-Core Processor |
| CPU vendor | AuthenticAMD |
| Physical cores | 12 |
| Logical CPUs | 24 |
| Frequency | 3000.0000–5660.2700 MHz reported by `lscpu` |
| RAM | 93Gi |
| OS/kernel | Debian GNU/Linux 12 (bookworm), kernel 6.1.0-43-amd64 |

Toolchains:
- `rustc 1.94.1 (e408947bf 2026-03-25) (built from a source tarball)`
- `go version go1.26.2 linux/amd64`
- `Elixir 1.20.0-rc.5 (compiled with Erlang/OTP 29)` / `Erlang/OTP 29.0`
- `ruby 3.4.9 (2026-03-11 revision 76cca827ab) +YJIT +PRISM [x86_64-linux]`
- `uv 0.11.11 (x86_64-unknown-linux-gnu)`
- `OpenSSL 3.6.1 27 Jan 2026 (Library: OpenSSL 3.6.1 27 Jan 2026)`

CPU caps are enforced natively per language (no containers): `GOMAXPROCS`, `TOKIO_WORKER_THREADS`, BEAM `+S N:N` (plus dirty / async pool caps), `falcon --count N`. Validity checks are included below; Go, Rust, and Ruby passed all checks, while all Elixir runs exceeded the 10% CPU-cap slack on this Linux/OTP 28 host.

## Baselines

| Lang   | Cores | rps    | p50 (µs) | p99 (µs) | server CPU | vs M4 Pro | validity |
|--------|-------|-------:|---------:|---------:|-----------:|----------:|----------|
| Ruby   | 1 | 5,346 | 51,967 | 76,223 | 99.9% | -31.5% | ok |
| Elixir | 1 | 7,932 | 32,335 | 40,191 | 127.4% | +12.1% | CAP FAIL |
| Go     | 1 | 6,772 | 20,863 | 131,071 | 100.1% | -12.2% | ok |
| Rust   | 1 | 27,657 | 9,079 | 12,407 | 99.9% | +36.3% | ok |
| Ruby   | 4 | 22,680 | 11,119 | 17,199 | 399.7% | -9.8% | ok |
| Elixir | 4 | 27,862 | 9,023 | 13,263 | 473.2% | -0.2% | CAP FAIL |
| Go     | 4 | 19,065 | 11,151 | 49,023 | 392.2% | -19.7% | ok |
| Rust   | 4 | 90,313 | 2,681 | 5,951 | 399.2% | +43.0% | ok |

Stacks:
- Ruby — Falcon + Rack + stdlib `json`, Ruby 3.4.9 with YJIT available.
- Elixir — Bandit + Plug + Jason on OTP 29 / Elixir 1.20.0-rc.5.
- Go — `net/http` stdlib + `encoding/json`, Go 1.26.2.
- Rust — axum 0.7 + serde_json + tokio multi-thread, Rust 1.94.1.

## Optimization rounds

| Lang   | Cores | Variant | rps | Δ vs baseline | p50 (µs) | p99 (µs) | server CPU | vs M4 Pro opt | validity |
|--------|-------|---------|----:|--------------:|---------:|---------:|-----------:|--------------:|----------|
| Ruby   | 1 | `oj` + YJIT | 6,450 | +20.7% | 40,319 | 54,111 | 99.9% | -32.0% | ok |
| Ruby   | 4 | `oj` + YJIT | 26,852 | +18.4% | 9,799 | 14,463 | 399.8% | -11.3% | ok |
| Elixir | 1 | OTP 29 `:json` | 8,778 | +10.7% | 29,215 | 35,871 | 126.6% | +12.6% | CAP FAIL |
| Elixir | 4 | OTP 29 `:json` | 30,685 | +10.1% | 8,191 | 12,127 | 475.0% | +2.2% | CAP FAIL |
| Go     | 1 | `goccy/go-json` + GOGC=200 | 11,477 | +69.5% | 18,223 | 97,023 | 100.2% | -7.2% | ok |
| Go     | 4 | `goccy/go-json` + GOGC=200 | 30,432 | +59.6% | 6,987 | 30,639 | 393.1% | -17.8% | ok |
| Rust   | 1 | `simd-json` + scratch buf | 27,452 | -0.7% | 9,119 | 12,223 | 99.9% | +28.3% | ok |
| Rust   | 4 | `simd-json` + scratch buf | 94,167 | +4.3% | 2,593 | 5,751 | 398.8% | +39.4% | ok |

Knobs:
- Ruby — enabled YJIT (`RUBY_YJIT_ENABLE=1`) and selected the `oj` JSON path (`WPB_JSON=oj`).
- Elixir — updated to Elixir 1.20.0-rc.5 compiled with OTP 29 and selected the OTP built-in `:json` module (`WPB_JSON=otp28`, retained as the env value name for the built-in backend).
- Go — replaced `encoding/json` with `goccy/go-json` and raised `GOGC` from 100 to 200.
- Rust — feature-gated `simd-json` for parsing and reused a scratch buffer for serialized output.

## Validity checks

The following runs failed at least one required validity check and should be treated as flagged rather than silently accepted:

| Result | rps | Reason |
|--------|----:|--------|
| `elixir-1c-elixir120rc5-otp29-jason` | 7,932 | cap_holds=false (127.4% avg vs 100% cap) |
| `elixir-1c-elixir120rc5-otp29-json` | 8,778 | cap_holds=false (126.6% avg vs 100% cap) |
| `elixir-4c-elixir120rc5-otp29-jason` | 27,862 | cap_holds=false (473.2% avg vs 400% cap) |
| `elixir-4c-elixir120rc5-otp29-json` | 30,685 | cap_holds=false (475.0% avg vs 400% cap) |

Investigation: the failing set is limited to Elixir. The harness launched BEAM with the intended scheduler cap flags (`+S N:N +SDcpu 1:1 +SDio 1 +A 1 +sbwt none +sbwtdcpu none +sbwtdio none`), errors stayed at zero, and the client was not bottlenecked. CPU sampling still measured ~127% at 1c and ~473–475% at 4c even after updating to OTP 29. This is materially worse drift than the M4 Pro note (~10–13%) and should be considered a platform/runtime cap limitation for these Elixir numbers on this host unless the harness is changed and re-run.

## Notable observations vs Apple M4 Pro

- Baseline 1c ranking on this host: Rust (27,657) > Elixir (7,932) > Go (6,772) > Ruby (5,346).
- Baseline 4c ranking on this host: Rust (90,313) > Elixir (27,862) > Ruby (22,680) > Go (19,065).
- Rust is much faster on this x86_64 Linux host than in the M4 Pro report: baseline Rust is +36.3% at 1c and +43.0% at 4c vs M4. Its optimized 4c run reaches 94,167 rps, +39.4% vs the M4 optimized Rust result.
- Rust `simd-json` behaved differently from the M4 Pro report: 1c was essentially flat/slightly down (-0.7%) while 4c improved +4.3%. The expected AVX2/AVX512 upside did not translate into a large 1c win for this payload; the 4c improvement was still smaller than the M4 Pro +7.0%.
- Go remains the biggest optimization story: `goccy/go-json` + `GOGC=200` improved +69.5% at 1c and +59.6% at 4c. Absolute Go throughput was lower than M4 Pro at both core counts, but the optimized 4c result still clears 30k rps.
- Ruby was slower than the M4 Pro at 1c (-31.5% baseline) but much closer at 4c (-9.8% baseline); `oj` + YJIT improved +20.7% at 1c and +18.4% at 4c, almost matching the M4 Pro relative gain.
- Elixir on OTP 29 improves over the previous OTP 28 x86_64 numbers: Jason baseline is +1.6% at both 1c and 4c, while the built-in `:json` variant is +10.7% over the updated Jason baseline at 1c and +10.1% at 4c. Every Elixir number is still validity-flagged because BEAM CPU usage exceeded the cap by ~27% at 1c and ~18–19% at 4c.
- Linux `/dev/null` plus this high-clock x86_64 server appears especially favorable to Rust: the 4c Rust client CPU was only ~177–186% of one core on a 24-logical-CPU host, so none of the Rust numbers were client-limited.

## How to reproduce

See `.claude/skills/load-test/SKILL.md`. These results used the standard defaults: `DURATION=30s`, `WARMUP=5s`, and `CONNECTIONS=256`.

```bash
for lang in go rust elixir ruby; do
  for cores in 1 4; do
    bench/run.sh "$lang" "$cores" baseline
  done
done

WPB_GO_TAGS=goccy GOGC=200 bench/run.sh go 1 goccy-gogc200 "goccy/go-json + GOGC=200"
WPB_GO_TAGS=goccy GOGC=200 bench/run.sh go 4 goccy-gogc200 "goccy/go-json + GOGC=200"
WPB_RUST_FEATURES=simd bench/run.sh rust 1 simd-json "simd-json + scratch buf"
WPB_RUST_FEATURES=simd bench/run.sh rust 4 simd-json "simd-json + scratch buf"
PATH="$HOME/.local/share/mise/installs/elixir/1.20.0-rc.5-otp-29/bin:$HOME/.local/share/mise/installs/erlang/29.0/bin:$PATH" \
  bench/run.sh elixir 1 elixir120rc5-otp29-jason "Elixir 1.20.0-rc.5 compiled with OTP 29 / Jason"
PATH="$HOME/.local/share/mise/installs/elixir/1.20.0-rc.5-otp-29/bin:$HOME/.local/share/mise/installs/erlang/29.0/bin:$PATH" \
  bench/run.sh elixir 4 elixir120rc5-otp29-jason "Elixir 1.20.0-rc.5 compiled with OTP 29 / Jason"
PATH="$HOME/.local/share/mise/installs/elixir/1.20.0-rc.5-otp-29/bin:$HOME/.local/share/mise/installs/erlang/29.0/bin:$PATH" \
  WPB_JSON=otp28 bench/run.sh elixir 1 elixir120rc5-otp29-json "Elixir 1.20.0-rc.5 compiled with OTP 29 / built-in :json"
PATH="$HOME/.local/share/mise/installs/elixir/1.20.0-rc.5-otp-29/bin:$HOME/.local/share/mise/installs/erlang/29.0/bin:$PATH" \
  WPB_JSON=otp28 bench/run.sh elixir 4 elixir120rc5-otp29-json "Elixir 1.20.0-rc.5 compiled with OTP 29 / built-in :json"
WPB_JSON=oj RUBY_YJIT_ENABLE=1 bench/run.sh ruby 1 oj-yjit "oj + YJIT"
WPB_JSON=oj RUBY_YJIT_ENABLE=1 bench/run.sh ruby 4 oj-yjit "oj + YJIT"
```

All committed result JSON files under `bench/results/` are the evidence for the tables above.
