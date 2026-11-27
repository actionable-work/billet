//! Requests, signatures and fixture secrets for the guestbook example.
//!
//! Fixture secrets are generated inside the VM and handed to the consumer; they
//! never reach Nix evaluation.
use crate::guest::{items, parse, read, succeed, text, wait_until_succeeds};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

/// Quote `value` as one POSIX shell word.
pub fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', r"'\''"))
}

/// HMAC-SHA256 (RFC 2104) of `message` under `key`, as lowercase hex.
fn hmac_sha256(key: &[u8], message: &[u8]) -> String {
    let mut block = [0_u8; 64];
    if key.len() > block.len() {
        block[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        block[..key.len()].copy_from_slice(key);
    }
    let pad = |byte: u8| block.iter().map(|value| value ^ byte).collect::<Vec<_>>();
    let inner = Sha256::new()
        .chain_update(pad(0x36))
        .chain_update(message)
        .finalize();
    let outer = Sha256::new()
        .chain_update(pad(0x5c))
        .chain_update(inner)
        .finalize();
    format!("{outer:x}")
}

/// Compact JSON as Python's `json.dumps(value, separators=(",", ":"))` writes
/// it: `ensure_ascii` escapes every non-ASCII character as UTF-16 `\uXXXX`.
fn python_json(value: &Value) -> String {
    let mut text = String::new();
    for character in value.to_string().chars() {
        if character.is_ascii() {
            text.push(character);
        } else {
            for unit in character.encode_utf16(&mut [0; 2]) {
                text.push_str(&format!("\\u{unit:04x}"));
            }
        }
    }
    text
}

/// The guestbook's signature over an entry's compact `[id, author, message]`.
fn signed(key: &str, entry: &Value) -> String {
    let text = python_json(&json!([entry["id"], entry["author"], entry["message"]]));
    hmac_sha256(key.as_bytes(), text.as_bytes())
}

/// Send a GET, or a JSON POST when `data` is given; return status and body.
pub fn request(url: &str, data: Option<&Value>) -> (u16, Value) {
    let mut command = format!(r"curl -sS -w '\n%{{http_code}}' {url}");
    if let Some(data) = data {
        command.push_str(&format!(
            " -H 'Content-Type: application/json' --data {}",
            quote(&data.to_string())
        ));
    }
    let output = succeed(&command);
    let (body, status) = output
        .rsplit_once('\n')
        .unwrap_or_else(|| panic!("no status: {output}"));
    (status.parse().expect("HTTP status"), parse(body))
}

/// The stored `(author, message)` pairs after checking every signature.
pub fn entries(url: &str, key: &str) -> Vec<(String, String)> {
    let (status, body) = request(&format!("{url}/entries"), None);
    assert_eq!(status, 200, "{body}");
    items(&body["entries"])
        .iter()
        .map(|entry| {
            assert_eq!(entry["signature"], signed(key, entry), "{entry}");
            (
                text(&entry["author"]).to_owned(),
                text(&entry["message"]).to_owned(),
            )
        })
        .collect()
}

/// Wait until every listed replica is ready and serves entries.
pub fn settle(urls: &[String]) {
    for url in urls {
        wait_until_succeeds(
            &format!("curl -fsS {url}/readyz && curl -fsS {url}/entries"),
            120,
        );
    }
}

pub fn create(url: &str, key: &str, author: &str, message: &str) {
    let (status, created) = request(
        &format!("{url}/entries"),
        Some(&json!({"author": author, "message": message})),
    );
    assert_eq!(status, 201, "{created}");
    let entry = json!({"id": created["id"], "author": author, "message": message});
    assert_eq!(created["signature"], signed(key, &entry));
}

pub struct Secrets {
    pub password: String,
    pub key: String,
}

pub fn secrets() -> Secrets {
    succeed("head -c 24 /dev/urandom | base64 -w0 > /tmp/db-password");
    succeed("head -c 32 /dev/urandom | base64 -w0 > /tmp/session-key");
    Secrets {
        password: read("/tmp/db-password"),
        key: read("/tmp/session-key"),
    }
}

pub fn pair(author: &str, message: &str) -> Vec<(String, String)> {
    vec![(author.to_owned(), message.to_owned())]
}

#[cfg(test)]
mod tests {
    use super::{hmac_sha256, python_json};
    use serde_json::json;

    #[test]
    fn json_escapes_non_ascii_like_python() {
        // json.dumps([7, "ada", "é \"😀\"\n"], separators=(",", ":"))
        assert_eq!(
            python_json(&json!([7, "ada", "é \"😀\"\n"])),
            r#"[7,"ada","\u00e9 \"\ud83d\ude00\"\n"]"#
        );
    }

    #[test]
    fn hmac_matches_rfc_4231() {
        assert_eq!(
            hmac_sha256(&[0x0b; 20], b"Hi There"),
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        );
        assert_eq!(
            hmac_sha256(b"Jefe", b"what do ya want for nothing?"),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
        assert_eq!(
            hmac_sha256(
                &[0xaa; 131],
                b"Test Using Larger Than Block-Size Key - Hash Key First"
            ),
            "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
        );
    }
}
