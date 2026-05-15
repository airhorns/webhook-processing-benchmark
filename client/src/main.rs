use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine;
use bytes::Bytes;
use clap::Parser;
use hdrhistogram::Histogram;
use hmac::{Hmac, Mac};
use http_body_util::{BodyExt, Full};
use hyper::{Method, Request};
use hyper_util::rt::TokioIo;
use sha2::Sha256;
use tokio::net::TcpStream;

type HmacSha256 = Hmac<Sha256>;

#[derive(Parser, Debug)]
#[command(about = "Webhook processing benchmark load generator")]
struct Args {
    #[arg(long, default_value = "http://127.0.0.1:8080/webhook")]
    url: String,

    #[arg(long, default_value_t = 256)]
    connections: usize,

    #[arg(long, default_value = "30s")]
    duration: humantime::Duration,

    #[arg(long, default_value = "5s")]
    warmup: humantime::Duration,

    #[arg(long, default_value = "shared/payload.json")]
    payload: String,

    #[arg(long, default_value = "shared/secret.txt")]
    secret_file: String,

    /// Print one summary JSON line at the end on stdout.
    #[arg(long, default_value_t = false)]
    json: bool,
}

struct Worker {
    addr: String,
    host_header: String,
    path: String,
    body: Bytes,
    hmac_b64: String,
    stop: Arc<AtomicBool>,
    measuring: Arc<AtomicBool>,
    sent: Arc<AtomicU64>,
    ok: Arc<AtomicU64>,
    errors: Arc<AtomicU64>,
}

impl Worker {
    async fn run(self) -> Histogram<u64> {
        let mut hist = Histogram::<u64>::new_with_bounds(1, 60_000_000, 3).unwrap();

        while !self.stop.load(Ordering::Relaxed) {
            if let Err(_) = self.connect_and_drive(&mut hist).await {
                // Reconnect on failure; small backoff to avoid spinning if server is down.
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        }
        hist
    }

    async fn connect_and_drive(&self, hist: &mut Histogram<u64>) -> anyhow::Result<()> {
        let stream = TcpStream::connect(&self.addr).await?;
        stream.set_nodelay(true)?;
        let io = TokioIo::new(stream);
        let (mut sender, conn) = hyper::client::conn::http1::handshake(io).await?;

        // Drive the connection.
        let conn_handle = tokio::spawn(async move {
            let _ = conn.await;
        });

        loop {
            if self.stop.load(Ordering::Relaxed) {
                break;
            }
            // Build the request fresh; Bytes::clone is cheap (refcount bump).
            let req = Request::builder()
                .method(Method::POST)
                .uri(&self.path)
                .header("host", &self.host_header)
                .header("content-type", "application/json")
                .header("x-shopify-topic", "products/create")
                .header("x-shopify-hmac-sha256", &self.hmac_b64)
                .header("x-shopify-shop-domain", "example.myshopify.com")
                .header("x-shopify-api-version", "2026-04")
                .body(Full::new(self.body.clone()))?;

            let measuring = self.measuring.load(Ordering::Relaxed);
            let t0 = Instant::now();
            let res = sender.send_request(req).await?;
            let status = res.status();
            // Drain body. For 200/empty this is a no-op-ish.
            let _ = res.into_body().collect().await?;
            let elapsed_us = t0.elapsed().as_micros() as u64;

            if measuring {
                self.sent.fetch_add(1, Ordering::Relaxed);
                if status.is_success() {
                    self.ok.fetch_add(1, Ordering::Relaxed);
                    let _ = hist.record(elapsed_us.max(1));
                } else {
                    self.errors.fetch_add(1, Ordering::Relaxed);
                }
            }
        }

        drop(sender);
        let _ = conn_handle.await;
        Ok(())
    }
}

// CPU usage of self (user + system) in seconds, via getrusage.
fn cpu_time_self() -> f64 {
    unsafe {
        let mut r: libc::rusage = std::mem::zeroed();
        libc::getrusage(libc::RUSAGE_SELF, &mut r);
        let u = r.ru_utime.tv_sec as f64 + (r.ru_utime.tv_usec as f64) * 1e-6;
        let s = r.ru_stime.tv_sec as f64 + (r.ru_stime.tv_usec as f64) * 1e-6;
        u + s
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    let uri: hyper::Uri = args.url.parse()?;
    let host = uri.host().ok_or_else(|| anyhow::anyhow!("url missing host"))?.to_string();
    let port = uri.port_u16().unwrap_or(80);
    let path = if uri.path().is_empty() { "/".to_string() } else { uri.path().to_string() };
    let addr = format!("{host}:{port}");
    let host_header = if port == 80 { host.clone() } else { format!("{host}:{port}") };

    let body_vec = tokio::fs::read(&args.payload).await?;
    let secret_raw = tokio::fs::read_to_string(&args.secret_file).await?;
    let secret = secret_raw.trim();

    let mut mac = HmacSha256::new_from_slice(secret.as_bytes())?;
    mac.update(&body_vec);
    let hmac_bytes = mac.finalize().into_bytes();
    let hmac_b64 = base64::engine::general_purpose::STANDARD.encode(hmac_bytes);

    let body = Bytes::from(body_vec);

    let stop = Arc::new(AtomicBool::new(false));
    let measuring = Arc::new(AtomicBool::new(false));
    let sent = Arc::new(AtomicU64::new(0));
    let ok = Arc::new(AtomicU64::new(0));
    let errors = Arc::new(AtomicU64::new(0));

    eprintln!(
        "client → POST {} ({} bytes), {} connections, warmup {}, duration {}",
        args.url,
        body.len(),
        args.connections,
        args.warmup,
        args.duration,
    );

    let mut handles = Vec::with_capacity(args.connections);
    for _ in 0..args.connections {
        let w = Worker {
            addr: addr.clone(),
            host_header: host_header.clone(),
            path: path.clone(),
            body: body.clone(),
            hmac_b64: hmac_b64.clone(),
            stop: stop.clone(),
            measuring: measuring.clone(),
            sent: sent.clone(),
            ok: ok.clone(),
            errors: errors.clone(),
        };
        handles.push(tokio::spawn(async move { w.run().await }));
    }

    // Warmup, then start measuring.
    tokio::time::sleep(args.warmup.into()).await;
    let cpu_start = cpu_time_self();
    let wall_start = Instant::now();
    measuring.store(true, Ordering::Relaxed);
    eprintln!("client → measuring for {}", args.duration);

    tokio::time::sleep(args.duration.into()).await;

    measuring.store(false, Ordering::Relaxed);
    let wall_elapsed = wall_start.elapsed();
    let cpu_elapsed = cpu_time_self() - cpu_start;
    stop.store(true, Ordering::Relaxed);

    // Wait for workers (with a short cap so we don't hang if a server hangs).
    let join_deadline = Instant::now() + Duration::from_secs(3);
    let mut merged = Histogram::<u64>::new_with_bounds(1, 60_000_000, 3).unwrap();
    for h in handles {
        match tokio::time::timeout_at(join_deadline.into(), h).await {
            Ok(Ok(local)) => {
                let _ = merged.add(&local);
            }
            _ => { /* leak it, we're exiting */ }
        }
    }

    let sent_n = sent.load(Ordering::Relaxed);
    let ok_n = ok.load(Ordering::Relaxed);
    let err_n = errors.load(Ordering::Relaxed);
    let rps = ok_n as f64 / wall_elapsed.as_secs_f64();

    let p50 = merged.value_at_quantile(0.5);
    let p90 = merged.value_at_quantile(0.9);
    let p99 = merged.value_at_quantile(0.99);
    let p999 = merged.value_at_quantile(0.999);
    let max = merged.max();

    let num_cpus = num_cpus_avail();
    let cpu_pct_of_one = (cpu_elapsed / wall_elapsed.as_secs_f64()) * 100.0;
    let cpu_pct_of_avail = cpu_pct_of_one / num_cpus as f64;

    let summary = serde_json::json!({
        "url": args.url,
        "connections": args.connections,
        "duration_s": wall_elapsed.as_secs_f64(),
        "sent": sent_n,
        "ok": ok_n,
        "errors": err_n,
        "rps": rps,
        "p50_us": p50,
        "p90_us": p90,
        "p99_us": p99,
        "p999_us": p999,
        "max_us": max,
        "client_cpu_total_s": cpu_elapsed,
        "client_cpu_pct_of_one_core": cpu_pct_of_one,
        "client_cpu_pct_of_avail": cpu_pct_of_avail,
        "client_avail_cores": num_cpus,
    });

    if args.json {
        println!("{}", summary);
    } else {
        eprintln!("\n=== client summary ===");
        eprintln!("{}", serde_json::to_string_pretty(&summary).unwrap());
    }

    Ok(())
}

fn num_cpus_avail() -> usize {
    std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1)
}
