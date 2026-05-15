use std::fs::OpenOptions;
use std::os::fd::AsRawFd;
use std::sync::Arc;

use axum::{
    body::Bytes,
    extract::State,
    http::{HeaderMap, StatusCode},
    routing::post,
    Router,
};
use base64::Engine;
use hmac::{Hmac, Mac};
use serde_json::Value;
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

struct AppState {
    secret: Vec<u8>,
    devnull_fd: i32,
}

#[derive(Clone)]
struct SharedState(Arc<AppState>);

fn upcase_in_place(v: &mut Value) {
    match v {
        Value::String(s) => {
            // String::to_uppercase allocates a new String; reassign.
            let upper = s.to_uppercase();
            *s = upper;
        }
        Value::Array(arr) => {
            for elem in arr.iter_mut() {
                upcase_in_place(elem);
            }
        }
        Value::Object(map) => {
            for (_k, val) in map.iter_mut() {
                upcase_in_place(val);
            }
        }
        _ => {}
    }
}

fn verify_hmac(secret: &[u8], body: &[u8], header: Option<&str>) -> bool {
    let Some(header) = header else { return false };
    let Ok(expected) = base64::engine::general_purpose::STANDARD.decode(header) else {
        return false;
    };
    let Ok(mut mac) = HmacSha256::new_from_slice(secret) else {
        return false;
    };
    mac.update(body);
    mac.verify_slice(&expected).is_ok()
}

#[inline]
fn write_fd(fd: i32, buf: &[u8]) {
    unsafe {
        let _ = libc::write(fd, buf.as_ptr() as *const _, buf.len());
    }
}

async fn webhook(
    State(state): State<SharedState>,
    headers: HeaderMap,
    body: Bytes,
) -> StatusCode {
    let hmac_header = headers
        .get("x-shopify-hmac-sha256")
        .and_then(|v| v.to_str().ok());

    if !verify_hmac(&state.0.secret, &body, hmac_header) {
        return StatusCode::UNAUTHORIZED;
    }

    let mut payload: Value = match parse_json(&body) {
        Ok(v) => v,
        Err(_) => return StatusCode::BAD_REQUEST,
    };

    let variants = match payload.get_mut("variants").and_then(Value::as_array_mut) {
        Some(a) => a,
        None => return StatusCode::BAD_REQUEST,
    };

    let fd = state.0.devnull_fd;
    SCRATCH.with(|cell| {
        let mut buf = cell.borrow_mut();
        for v in variants.iter_mut() {
            upcase_in_place(v);
            buf.clear();
            if serde_json::to_writer(&mut *buf, v).is_ok() {
                buf.push(b'\n');
                write_fd(fd, &buf);
            }
        }
    });

    StatusCode::OK
}

#[cfg(not(feature = "simd"))]
fn parse_json(body: &[u8]) -> Result<Value, serde_json::Error> {
    serde_json::from_slice(body)
}

#[cfg(feature = "simd")]
fn parse_json(body: &[u8]) -> Result<Value, simd_json::Error> {
    let mut owned = body.to_vec();
    simd_json::serde::from_slice(&mut owned)
}

thread_local! {
    static SCRATCH: std::cell::RefCell<Vec<u8>> = std::cell::RefCell::new(Vec::with_capacity(4096));
}

fn main() -> anyhow::Result<()> {
    let workers: usize = std::env::var("TOKIO_WORKER_THREADS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or_else(num_cpus_avail);

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(workers)
        .enable_all()
        .build()?;

    rt.block_on(async_main(workers))
}

fn num_cpus_avail() -> usize {
    std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1)
}

async fn async_main(workers: usize) -> anyhow::Result<()> {
    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(8080);
    let secret_path = std::env::var("HMAC_SECRET_FILE")
        .unwrap_or_else(|_| "../../shared/secret.txt".to_string());

    let secret_raw = std::fs::read_to_string(&secret_path)?;
    let secret = secret_raw.trim().as_bytes().to_vec();

    let devnull = OpenOptions::new()
        .write(true)
        .append(true)
        .open("/dev/null")?;
    let devnull_fd = devnull.as_raw_fd();
    // Keep the File alive for the whole process so the fd is valid.
    Box::leak(Box::new(devnull));

    let state = SharedState(Arc::new(AppState {
        secret,
        devnull_fd,
    }));

    let app = Router::new()
        .route("/webhook", post(webhook))
        .with_state(state);

    let addr = std::net::SocketAddr::from(([127, 0, 0, 1], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    eprintln!(
        "rust (axum) server listening on {} ({} tokio worker thread{})",
        addr,
        workers,
        if workers == 1 { "" } else { "s" }
    );

    axum::serve(listener, app).await?;
    Ok(())
}
