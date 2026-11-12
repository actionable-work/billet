use crate::common::*;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

pub fn ir() -> Result {
    let prefix = nix_expression();
    let cases = [
        ("wrongType", "resources.cpuLimit"),
        ("inlineSecret", "secrets.database.value"),
        ("secretType", "secrets.database.external"),
        ("unknown", "applications"),
        ("probePort", "probes.readiness.port"),
        ("mount", "storage.mountPoint"),
        ("schemaVersion", "schemaVersion"),
    ];
    for (name, field) in cases {
        let result = evaluate(&format!("{prefix}(f.evaluate f.invalid.{name}).ir"))?;
        let error = String::from_utf8(result.stderr)?;
        check(
            !result.status.success() && error.contains(&format!("billet: {field}:")),
            &error,
        )?;
        check(
            !error.contains("DO-NOT-ECHO-SECRET"),
            "rejected value leaked to diagnostic",
        )?;
    }
    let payload = std::fs::read(env("manifest"))?;
    for _ in 0..2 {
        let output = success(evaluate(&format!("{prefix}f.sample.canonicalJSON"))?)?;
        let repeated: String = serde_json::from_slice(&output.stdout)?;
        check(
            repeated.as_bytes() == payload,
            "independent canonical evaluation differs",
        )?;
    }
    let base_bytes = std::fs::read(env("baseManifest"))?;
    let base: Value = serde_json::from_slice(&base_bytes)?;
    let symbolic = String::from_utf8(base_bytes)?
        .replace(text(&base["process"]["package"]), "@PACKAGE@")
        .replace(text(&base["system"]), "@SYSTEM@");
    check(
        symbolic.as_bytes()
            == std::fs::read(Path::new(&env("source")).join("tests/golden/hello-v1.json"))?,
        "v1 golden changed without migration",
    )?;
    let mut command = std::process::Command::new(text(&base["process"]["executable"]));
    command.args(array(&base["process"]["argv"]).iter().map(text));
    check(
        success(command.output()?)?.stdout == b"Hello from Billet\n",
        "example output differs",
    )?;
    let value: Value = serde_json::from_slice(&payload)?;
    check(
        !payload.ends_with(b"\n")
            && value["normalizationVersion"] == 1
            && value["schemaVersion"] == 1,
        "invalid canonical encoding",
    )?;
    check(
        value["process"]["argv"] == serde_json::json!(["", "two words", "$(not-a-shell)", "a;b"]),
        "argv flattened",
    )?;
    check(
        value["restart"]["maxRetries"] == 5
            && value["shutdown"]["stopGracePeriodSeconds"] == 30
            && value["rollout"]["progressDeadlineSeconds"] == 600
            && value["rollout"]["automaticRollback"] == true,
        "effective defaults changed",
    )?;
    check(
        value["secrets"]["database"]
            == serde_json::json!({"external":"runtime/database","mode":"file","required":true,"target":"/run/secrets/database"}),
        "secret reference changed",
    )?;
    for entry in std::fs::read_dir(env("descriptor"))? {
        check(
            !String::from_utf8_lossy(&std::fs::read(entry?.path())?).contains("DO-NOT-ECHO-SECRET"),
            "secret canary in descriptor artifact",
        )?;
    }
    let derivation = std::fs::read_to_string(env("derivationSpec"))?;
    check(
        !derivation.contains("DO-NOT-ECHO-SECRET")
            && derivation.contains("runtime/database")
            && derivation.contains("runtime/token"),
        "secret references in derivation differ",
    )?;
    println!(
        "Canonical IR, independent evaluations, seven value-free diagnostics and secret artifacts verified"
    );
    Ok(())
}

pub fn closure() -> Result {
    let directory = env("descriptor");
    let descriptor = json(Path::new(&directory).join("descriptor.json"))?;
    let payload = std::fs::read(Path::new(&directory).join("manifest.json"))?;
    let ir: Value = serde_json::from_slice(&payload)?;
    check(
        descriptor["schemaVersion"] == 1
            && text(&descriptor["manifestDigest"]) == digest(&payload)
            && descriptor["system"] == ir["system"],
        "closure identity mismatch",
    )?;
    let roots: Value = serde_json::from_str(&env("expectedRoots"))?;
    check(descriptor["roots"] == roots, "closure roots differ")?;
    let nodes: BTreeMap<String, &Value> = array(&descriptor["paths"])
        .iter()
        .map(|v| (text(&v["path"]).to_owned(), v))
        .collect();
    let ordered: Vec<&str> = array(&descriptor["paths"])
        .iter()
        .map(|v| text(&v["path"]))
        .collect();
    check(
        ordered == nodes.keys().map(String::as_str).collect::<Vec<_>>(),
        "closure paths not sorted/unique",
    )?;
    let expected: Vec<String> = serde_json::from_str(&env("expectedPaths"))?;
    check(
        expected.iter().all(|p| nodes.contains_key(p))
            && !nodes.contains_key(&env("forbiddenPath")),
        "missing or unrelated runtime path",
    )?;
    let edges: Vec<(String, String)> = serde_json::from_str(&env("expectedEdges"))?;
    for (source, target) in edges {
        check(
            array(&nodes[&source]["references"])
                .iter()
                .any(|v| text(v) == target),
            "transitive fixture edge missing",
        )?;
    }
    let mut reached = BTreeSet::new();
    let mut pending: Vec<String> = array(&roots).iter().map(|v| text(v).to_owned()).collect();
    while let Some(path) = pending.pop() {
        if !reached.insert(path.clone()) {
            continue;
        }
        let node = nodes.get(&path).ok_or("reference missing from closure")?;
        let references: Vec<String> = array(&node["references"])
            .iter()
            .map(|v| text(v).to_owned())
            .collect();
        check(
            references.windows(2).all(|w| w[0] < w[1]),
            "references not sorted/unique",
        )?;
        pending.extend(references);
        verify_nar(&path, node)?;
    }
    check(
        reached == nodes.keys().cloned().collect(),
        "unreachable closure paths",
    )?;
    println!(
        "Verified {} runtime paths, transitive edges and actual NAR identities",
        nodes.len()
    );
    Ok(())
}

fn verify_nar(path: &str, node: &Value) -> Result {
    let nar = invoke("nix-store", &["--dump", path])?.stdout;
    check(
        node["narSize"].as_u64() == Some(nar.len() as u64) && !nar.is_empty(),
        "NAR size mismatch",
    )?;
    let identity = digest(&nar);
    let base32 = invoke(
        "nix-hash",
        &["--type", "sha256", "--to-base32", &identity[7..]],
    )?;
    check(
        text(&node["narHash"]) == format!("sha256:{}", String::from_utf8(base32.stdout)?.trim()),
        "NAR hash mismatch",
    )
}

pub fn preflight() -> Result {
    let reports: Value = serde_json::from_str(&env("reportsJSON"))?;
    for name in ["full", "trap", "invalidUser"] {
        let report = &reports[name];
        check(
            report["schemaVersion"] == 1
                && report["profileVersion"] == 1
                && report["rendererVersion"] == 1
                && report["canRender"] == false
                && array(&report["supportedCapabilities"]).is_empty(),
            "preflight claimed conformance",
        )?;
        let rejected: BTreeSet<&str> = array(&report["diagnostics"])
            .iter()
            .filter(|d| d["code"] == "UnsupportedCapability")
            .map(|d| text(&d["capability"]))
            .collect();
        check(
            rejected
                == array(&report["requiredCapabilities"])
                    .iter()
                    .map(text)
                    .collect(),
            "required capability silently omitted",
        )?;
    }
    let fields: BTreeSet<&str> = array(&reports["full"]["diagnostics"])
        .iter()
        .map(|d| text(&d["field"]))
        .collect();
    check(
        [
            "restart",
            "initialization.steps",
            "probes",
            "secrets",
            "storage",
            "requiredCapabilities",
        ]
        .iter()
        .all(|f| fields.contains(f)),
        "owning field diagnostics missing",
    )?;
    check(
        reports["arm"]["supported"] == true
            && reports["arm"]["architecture"] == "arm64"
            && reports["darwin"]["supported"] == false
            && reports["mismatch"]["supported"] == false
            && reports["invalidUser"]["image"]["supported"] == false,
        "system/user profile weakened",
    )?;
    let result = evaluate(&format!(
        "{}f.sample.dockerCompose.configuration",
        nix_expression()
    ))?;
    let error = String::from_utf8(result.stderr)?;
    check(
        !result.status.success()
            && error.contains("UnsupportedTarget dockerCompose")
            && error.contains("restart:")
            && !error.contains("DO-NOT-ECHO-SECRET"),
        "configuration did not reject with redacted fields",
    )?;
    println!("Pure preflight, required defaults, systems/users and pre-build rejection verified");
    Ok(())
}
