use serde::de::{self, Deserialize, Deserializer, MapAccess, SeqAccess, Visitor};
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;
use std::ffi::OsString;
use std::fmt;
use std::fs::File;
use std::io::{self, BufReader, Write};
use std::path::Path;

struct ManifestValue(Value);

impl<'de> Deserialize<'de> for ManifestValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(ManifestVisitor).map(Self)
    }
}

struct ManifestVisitor;

impl<'de> Visitor<'de> for ManifestVisitor {
    type Value = Value;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a JSON value with unique object fields")
    }

    fn visit_bool<E: de::Error>(self, value: bool) -> Result<Value, E> {
        Ok(value.into())
    }

    fn visit_i64<E: de::Error>(self, value: i64) -> Result<Value, E> {
        Ok(value.into())
    }

    fn visit_u64<E: de::Error>(self, value: u64) -> Result<Value, E> {
        Ok(value.into())
    }

    fn visit_f64<E: de::Error>(self, value: f64) -> Result<Value, E> {
        Ok(value.into())
    }

    fn visit_str<E: de::Error>(self, value: &str) -> Result<Value, E> {
        Ok(value.into())
    }

    fn visit_unit<E: de::Error>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Value, A::Error> {
        let mut items = Vec::new();
        while let Some(ManifestValue(value)) = seq.next_element()? {
            items.push(value);
        }
        Ok(Value::Array(items))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Value, A::Error> {
        let mut fields = Map::new();
        while let Some((key, ManifestValue(value))) = map.next_entry()? {
            if fields.insert(key, value).is_some() {
                return Err(de::Error::custom("duplicate object field"));
            }
        }
        Ok(Value::Object(fields))
    }
}

fn has_supported_numbers(value: &Value) -> bool {
    match value {
        Value::Number(number) => number.is_i64(),
        Value::Array(items) => items.iter().all(has_supported_numbers),
        Value::Object(fields) => fields.values().all(has_supported_numbers),
        _ => true,
    }
}

fn read_manifest(side: &str, path: &Path) -> Result<Value, String> {
    let file = File::open(path).map_err(|_| format!("cannot open {side} manifest"))?;
    let ManifestValue(manifest) = serde_json::from_reader(BufReader::new(file))
        .map_err(|_| format!("cannot read {side} manifest as JSON"))?;
    if !manifest.is_object() {
        return Err(format!("{side} manifest must be a JSON object"));
    }
    for field in ["schemaVersion", "normalizationVersion"] {
        if manifest[field].as_u64() != Some(1) {
            return Err(format!("{side} manifest requires {field} 1"));
        }
    }
    if !has_supported_numbers(&manifest) {
        return Err(format!(
            "{side} manifest numbers require canonical signed 64-bit integers"
        ));
    }
    Ok(manifest)
}

fn compare(before: &Value, after: &Value, path: &str, changes: &mut Vec<Value>) {
    if let (Some(before), Some(after)) = (before.as_object(), after.as_object()) {
        let keys: BTreeSet<_> = before.keys().chain(after.keys()).collect();
        for key in keys {
            let key_pointer = key.replace('~', "~0").replace('/', "~1");
            let child = format!("{path}/{key_pointer}");
            match (before.get(key), after.get(key)) {
                (Some(old), Some(new)) => compare(old, new, &child, changes),
                (None, _) => changes.push(json!({"op": "add", "path": child})),
                (_, None) => changes.push(json!({"op": "remove", "path": child})),
            }
        }
    } else if before != after {
        changes.push(json!({"op": "replace", "path": path}));
    }
}

fn diff(files: &[OsString]) -> Result<i32, String> {
    let [before, after] = files else {
        return Err("usage: billet diff BEFORE.json AFTER.json".into());
    };
    let before = read_manifest("before", Path::new(before))?;
    let after = read_manifest("after", Path::new(after))?;
    let mut changes = Vec::new();
    compare(&before, &after, "", &mut changes);

    let mut stdout = io::stdout().lock();
    serde_json::to_writer(&mut stdout, &changes).map_err(|_| "cannot write manifest diff")?;
    writeln!(stdout).map_err(|_| "cannot write manifest diff")?;
    Ok(i32::from(!changes.is_empty()))
}

pub(crate) fn run(files: &[OsString]) -> i32 {
    match diff(files) {
        Ok(status) => status,
        Err(error) => {
            eprintln!("billet: {error}");
            2
        }
    }
}
