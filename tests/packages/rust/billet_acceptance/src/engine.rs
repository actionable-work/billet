//! A minimal Docker Engine endpoint that records the pinned Compose consumer's
//! container create request instead of creating a container.
use crate::common::{Result, Temporary, check};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// The Engine nanocores the Compose CPU ceiling must produce.
const MAXIMUM_NANO_CPUS: i64 = 9_223_370_937_343_148_032;

struct Request {
    method: String,
    path: String,
    body: Vec<u8>,
}

fn read_request(stream: &UnixStream) -> Result<Request> {
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let mut parts = line.split_whitespace();
    let method = parts.next().unwrap_or_default().to_owned();
    let target = parts.next().unwrap_or_default();
    let mut length = 0;
    loop {
        let mut header = String::new();
        reader.read_line(&mut header)?;
        let header = header.trim_end();
        if header.is_empty() {
            break;
        }
        if let Some((name, value)) = header.split_once(':')
            && name.eq_ignore_ascii_case("content-length")
        {
            length = value.trim().parse()?;
        }
    }
    let mut body = vec![0; length];
    reader.read_exact(&mut body)?;
    Ok(Request {
        method,
        path: api_path(target),
        body,
    })
}

/// Strip the query and an optional `/vX.Y` API version prefix.
fn api_path(target: &str) -> String {
    let path = target.split('?').next().unwrap_or_default();
    match path
        .strip_prefix("/v")
        .and_then(|rest| rest.split_once('/'))
    {
        Some((version, rest)) if version.split('.').all(|part| part.parse::<u32>().is_ok()) => {
            format!("/{rest}")
        }
        _ => path.to_owned(),
    }
}

fn route(
    request: &Request,
    architecture: &str,
    creates: &Mutex<Vec<Value>>,
) -> Result<(u16, Option<Value>)> {
    let path = request.path.as_str();
    Ok(match path {
        "/_ping" => (200, None),
        "/containers/json" | "/networks" => (200, Some(json!([]))),
        "/volumes" => (200, Some(json!({"Volumes": []}))),
        "/networks/create" => (201, Some(json!({"Id": "b".repeat(64)}))),
        "/containers/create" => {
            creates
                .lock()
                .map_err(|_| "poisoned")?
                .push(serde_json::from_slice(&request.body)?);
            (
                400,
                Some(json!({"message": "Billet test recorded the container create request"})),
            )
        }
        _ if path.starts_with("/images/") && path.ends_with("/json") => (
            200,
            Some(
                json!({"Id": format!("sha256:{}", "a".repeat(64)), "Os": "linux", "Architecture": architecture, "Config": {}}),
            ),
        ),
        _ => (
            404,
            Some(
                json!({"message": format!("Unexpected Engine endpoint: {} {path}", request.method)}),
            ),
        ),
    })
}

fn respond(mut stream: &UnixStream, status: u16, payload: Option<Value>, head: bool) -> Result {
    let body = payload.map(|value| value.to_string()).unwrap_or_default();
    write!(
        stream,
        "HTTP/1.0 {status} Billet\r\nAPI-Version: 1.54\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )?;
    if !head {
        stream.write_all(body.as_bytes())?;
    }
    Ok(stream.flush()?)
}

fn serve(stream: &UnixStream, architecture: &str, creates: &Mutex<Vec<Value>>) -> Result {
    let request = read_request(stream)?;
    let (status, payload) = route(&request, architecture, creates)?;
    respond(stream, status, payload, request.method == "HEAD")
}

fn listen(listener: UnixListener, architecture: String, creates: Arc<Mutex<Vec<Value>>>) {
    for stream in listener.incoming().flatten() {
        let (architecture, creates) = (architecture.clone(), Arc::clone(&creates));
        std::thread::spawn(move || {
            if let Err(error) = serve(&stream, &architecture, &creates) {
                eprintln!("engine request failed: {error}");
            }
        });
    }
}

/// Run `compose create` against the stand-in and wait at most 30 seconds.
fn create(compose: &str, config: &str, socket: &str, home: &str) -> Result<String> {
    let mut child = Command::new(compose)
        .args([
            "--project-name",
            "billet-cpu",
            "--file",
            config,
            "create",
            "--no-build",
            "--pull",
            "never",
        ])
        .env("DOCKER_HOST", format!("unix://{socket}"))
        .env("DOCKER_CONFIG", home)
        .env_remove("DOCKER_CONTEXT")
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()?;
    let deadline = Instant::now() + Duration::from_secs(30);
    while child.try_wait()?.is_none() {
        if Instant::now() > deadline {
            child.kill()?;
            return Err("compose create timed out".into());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let mut stderr = String::new();
    child
        .stderr
        .take()
        .ok_or("no stderr")?
        .read_to_string(&mut stderr)?;
    Ok(stderr)
}

/// The pinned Compose consumer sends the CPU ceiling as the expected nanocores.
pub fn verify(compose: &str, config: &str, architecture: &str) -> Result {
    let directory = Temporary::new()?;
    let home = directory.0.to_str().ok_or("non-UTF-8 temporary path")?;
    let socket = format!("{home}/engine.sock");
    let listener = UnixListener::bind(&socket)?;
    let creates = Arc::new(Mutex::new(Vec::new()));
    let recorder = Arc::clone(&creates);
    let architecture = architecture.to_owned();
    std::thread::spawn(move || listen(listener, architecture, recorder));
    let stderr = create(compose, config, &socket, home)?;
    let creates = creates.lock().map_err(|_| "poisoned")?;
    check(
        creates.len() == 1,
        &format!("expected one create request: {stderr}"),
    )?;
    let nano_cpus = creates[0]["HostConfig"]["NanoCpus"].as_i64();
    check(
        nano_cpus == Some(MAXIMUM_NANO_CPUS),
        &format!("unexpected NanoCpus in {}", creates[0]),
    )
}
