//! Shell, JSON and parameter helpers for assertions that run inside a guest.
//!
//! Commands run through `/bin/sh -c`, as the NixOS test driver runs them. A
//! failed command or assertion panics, which exits nonzero and fails the
//! driver's `succeed` call that started this binary.
use serde_json::Value;
use std::collections::BTreeSet;
use std::process::Command;
use std::time::{Duration, Instant};

/// Run `command` and return its exit status and standard output.
pub fn execute(command: &str) -> (i32, String) {
    eprintln!("+ {command}");
    let output = Command::new("/bin/sh")
        .args(["-c", command])
        .output()
        .unwrap_or_else(|error| panic!("cannot start /bin/sh: {error}"));
    eprint!("{}", String::from_utf8_lossy(&output.stderr));
    let stdout = String::from_utf8(output.stdout).expect("UTF-8 command output");
    (output.status.code().unwrap_or(-1), stdout)
}

/// Run `command`, require success and return its standard output.
pub fn succeed(command: &str) -> String {
    let (status, stdout) = execute(command);
    assert_eq!(status, 0, "command failed: {command}\n{stdout}");
    stdout
}

/// Run `command`, require failure and return its standard output.
pub fn fail(command: &str) -> String {
    let (status, stdout) = execute(command);
    assert_ne!(
        status, 0,
        "command unexpectedly succeeded: {command}\n{stdout}"
    );
    stdout
}

/// Retry `command` once per second until it succeeds or `seconds` elapse.
pub fn wait_until_succeeds(command: &str, seconds: u64) -> String {
    let deadline = Instant::now() + Duration::from_secs(seconds);
    loop {
        let (status, stdout) = execute(command);
        if status == 0 {
            return stdout;
        }
        assert!(
            Instant::now() < deadline,
            "timed out after {seconds}s: {command}"
        );
        std::thread::sleep(Duration::from_secs(1));
    }
}

/// Poll `probe` once per second until it returns a value; after `seconds`, log
/// `diagnostics` and fail.
pub fn wait_for<T>(
    seconds: u64,
    what: &str,
    diagnostics: &[String],
    mut probe: impl FnMut() -> Option<T>,
) -> T {
    let deadline = Instant::now() + Duration::from_secs(seconds);
    loop {
        if let Some(value) = probe() {
            return value;
        }
        if Instant::now() >= deadline {
            for diagnostic in diagnostics {
                execute(&format!("{diagnostic} >&2"));
            }
            panic!("timed out after {seconds}s waiting for {what}");
        }
        std::thread::sleep(Duration::from_secs(1));
    }
}

/// Run `command` and parse its standard output as JSON.
pub fn json(command: &str) -> Value {
    parse(&succeed(command))
}

pub fn parse(text: &str) -> Value {
    serde_json::from_str(text).unwrap_or_else(|error| panic!("invalid JSON ({error}): {text}"))
}

/// Read a file as text.
pub fn read(path: &str) -> String {
    std::fs::read_to_string(path).unwrap_or_else(|error| panic!("cannot read {path}: {error}"))
}

/// Read a file as JSON.
pub fn read_json(path: &str) -> Value {
    parse(&read(path))
}

/// The string at `value`, which must be a JSON string.
pub fn text(value: &Value) -> &str {
    value
        .as_str()
        .unwrap_or_else(|| panic!("expected a string, got {value}"))
}

/// The elements of `value`, which must be a JSON array.
pub fn items(value: &Value) -> &Vec<Value> {
    value
        .as_array()
        .unwrap_or_else(|| panic!("expected an array, got {value}"))
}

/// The field names of `value`, which must be a JSON object.
pub fn keys(value: &Value) -> BTreeSet<String> {
    value
        .as_object()
        .unwrap_or_else(|| panic!("expected an object, got {value}"))
        .keys()
        .cloned()
        .collect()
}

/// A set of owned strings for comparison with [`keys`].
pub fn set(names: &[&str]) -> BTreeSet<String> {
    names.iter().map(|name| (*name).to_owned()).collect()
}

/// Require that none of `names` is a field of `value`.
pub fn lacks(value: &Value, names: &[&str]) {
    for name in names {
        assert!(
            value.get(name).is_none(),
            "unexpected field {name} in {value}"
        );
    }
}

/// The only element of `values`.
pub fn single<T: std::fmt::Debug>(values: Vec<T>) -> T {
    assert_eq!(values.len(), 1, "expected exactly one value: {values:?}");
    values.into_iter().next().expect("one value")
}

/// Print a section heading for the driver log.
pub fn section(name: &str) {
    eprintln!("=== {name}");
}

/// Nix-written parameters for one qualification run.
pub struct Params(Value);

impl Params {
    pub fn load(path: &str) -> Self {
        Self(read_json(path))
    }

    /// The string parameter `name`.
    pub fn s(&self, name: &str) -> &str {
        self.0
            .get(name)
            .and_then(Value::as_str)
            .unwrap_or_else(|| panic!("missing string parameter {name}"))
    }

    /// The parameter `name` as JSON.
    pub fn v(&self, name: &str) -> &Value {
        self.0
            .get(name)
            .unwrap_or_else(|| panic!("missing parameter {name}"))
    }

    /// The integer parameter `name`.
    pub fn n(&self, name: &str) -> i64 {
        self.v(name)
            .as_i64()
            .unwrap_or_else(|| panic!("parameter {name} is not an integer"))
    }
}

/// Run `command`; on failure, log `diagnostics` and fail with its output.
pub fn require(command: &str, diagnostics: &[String]) -> String {
    let (status, output) = execute(command);
    if status != 0 {
        for diagnostic in diagnostics {
            execute(&format!("{diagnostic} >&2"));
        }
    }
    assert_eq!(status, 0, "{command}\n{output}");
    output
}
