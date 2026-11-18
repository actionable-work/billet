use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

pub type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error>>;

pub fn env(key: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| panic!("missing fixture input: {key}"))
}
pub fn json(path: impl AsRef<Path>) -> Result<Value> {
    Ok(serde_json::from_slice(&std::fs::read(path)?)?)
}
pub fn digest(bytes: &[u8]) -> String {
    format!("sha256:{:x}", Sha256::digest(bytes))
}
pub fn check(condition: bool, reason: &str) -> Result {
    if condition {
        Ok(())
    } else {
        Err(reason.into())
    }
}
pub fn text(value: &Value) -> &str {
    value.as_str().expect("fixture string")
}
pub fn array(value: &Value) -> &Vec<Value> {
    value.as_array().expect("fixture array")
}
pub fn success(output: Output) -> Result<Output> {
    check(
        output.status.success(),
        &String::from_utf8_lossy(&output.stderr),
    )?;
    Ok(output)
}
pub fn invoke(program: &str, args: &[&str]) -> Result<Output> {
    success(Command::new(program).args(args).output()?)
}

pub struct Temporary(pub PathBuf);
impl Temporary {
    pub fn new() -> Result<Self> {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let base = std::env::temp_dir();
        for _ in 0..100 {
            let nonce = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)?
                .as_nanos();
            let path = base.join(format!(
                "billet-{}-{nonce}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            match std::fs::create_dir(&path) {
                Ok(()) => return Ok(Self(path)),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error.into()),
            }
        }
        Err("could not allocate fixture directory".into())
    }
}
impl Drop for Temporary {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

pub fn nix_expression() -> String {
    format!(
        "let pkgs = import {} {{ system = \"{}\"; }}; lib = pkgs.lib; billetLib = import {}/lib {{ inherit lib; }}; f = import {}/tests/fixtures.nix {{ inherit pkgs billetLib; }}; in ",
        env("nixpkgsSource"),
        env("system"),
        env("source"),
        env("source")
    )
}
pub fn evaluate(expression: &str) -> Result<Output> {
    Ok(Command::new("nix-instantiate")
        .args([
            "--store", "dummy://", "--eval", "--strict", "--json", "--expr", expression,
        ])
        .output()?)
}
