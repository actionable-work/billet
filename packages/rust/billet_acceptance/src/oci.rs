use crate::common::*;
use flate2::read::GzDecoder;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::io::{Cursor, Read};
use std::os::unix::fs::PermissionsExt;
use std::path::{Component, Path};

struct Node {
    mode: u32,
    kind: tar::EntryType,
    link: Option<std::path::PathBuf>,
    bytes: Vec<u8>,
}

fn blob(directory: &Path, reference: &Value, reached: &mut BTreeSet<String>) -> Result<Vec<u8>> {
    let identity = text(&reference["digest"]);
    check(
        identity.starts_with("sha256:"),
        "unsupported OCI blob digest",
    )?;
    let data = std::fs::read(directory.join("blobs/sha256").join(&identity[7..]))?;
    check(
        digest(&data) == identity && reference["size"].as_u64() == Some(data.len() as u64),
        "OCI blob digest/size mismatch",
    )?;
    reached.insert(identity[7..].to_owned());
    Ok(data)
}

fn layer(data: Vec<u8>, media: &str, nodes: &mut BTreeMap<String, Node>) -> Result<String> {
    let mut bytes = Vec::new();
    if media.ends_with("+gzip") {
        GzDecoder::new(data.as_slice()).read_to_end(&mut bytes)?;
    } else {
        check(media.ends_with(".tar"), "unsupported OCI layer encoding")?;
        bytes = data;
    }
    let diff_id = digest(&bytes);
    let mut archive = tar::Archive::new(Cursor::new(bytes));
    let mut names = BTreeSet::new();
    for item in archive.entries()? {
        let mut item = item?;
        let path = item.path()?.into_owned();
        check(
            !path
                .components()
                .any(|c| matches!(c, Component::ParentDir | Component::Prefix(_))),
            "parent traversal in image layer path",
        )?;
        // nix2container uses root-prefixed tar names. Interpret these within the
        // image; no archive entries are ever extracted onto the host filesystem.
        let name = path
            .components()
            .filter_map(|c| match c {
                Component::Normal(name) => Some(name),
                _ => None,
            })
            .collect::<std::path::PathBuf>()
            .to_string_lossy()
            .into_owned();
        check(
            names.insert(name.clone()),
            "duplicate path within OCI layer",
        )?;
        let header = item.header();
        check(
            header.uid()? == 0 && header.gid()? == 0 && header.mtime()? == 1,
            "backend ownership/time not reproducible",
        )?;
        let kind = header.entry_type();
        check(
            kind.is_dir() || kind.is_file() || kind.is_symlink(),
            "unsupported image node",
        )?;
        let mut node = Node {
            mode: header.mode()?,
            kind,
            link: item.link_name()?.map(|s| s.into_owned()),
            bytes: Vec::new(),
        };
        if kind.is_file() {
            item.read_to_end(&mut node.bytes)?;
        }
        if let Some(previous) = nodes.get(&name) {
            check(
                previous.kind.is_dir() && kind.is_dir(),
                "duplicate file across image layers",
            )?;
        }
        nodes.insert(name, node);
    }
    Ok(diff_id)
}

fn tree(path: &Path, nodes: &BTreeMap<String, Node>, expected: &mut BTreeSet<String>) -> Result {
    let name = path.to_string_lossy().trim_start_matches('/').to_owned();
    expected.insert(name.clone());
    let node = nodes
        .get(&name)
        .ok_or_else(|| format!("runtime path missing: {name}"))?;
    let metadata = path.symlink_metadata()?;
    check(
        node.mode == metadata.permissions().mode() & 0o7777,
        "store executable mode changed",
    )?;
    if metadata.file_type().is_symlink() {
        check(
            node.kind.is_symlink()
                && node.link.as_deref() == Some(std::fs::read_link(path)?.as_path()),
            "store symlink changed",
        )?;
    } else if metadata.is_file() {
        check(
            node.kind.is_file() && digest(&node.bytes) == digest(&std::fs::read(path)?),
            "store file contents changed",
        )?;
    } else {
        check(node.kind.is_dir(), "store directory changed")?;
        for entry in std::fs::read_dir(path)? {
            tree(&entry?.path(), nodes, expected)?;
        }
    }
    Ok(())
}

pub fn verify() -> Result {
    let directory_string = env("image");
    let directory = Path::new(&directory_string);
    let descriptor_directory = std::path::PathBuf::from(env("descriptor"));
    let descriptor_bytes = std::fs::read(descriptor_directory.join("descriptor.json"))?;
    let manifest_bytes = std::fs::read(descriptor_directory.join("manifest.json"))?;
    let descriptor: Value = serde_json::from_slice(&descriptor_bytes)?;
    let ir: Value = serde_json::from_slice(&manifest_bytes)?;
    let native = json(env("nativeImage"))?;
    check(
        native["version"] == 1
            && native["image-config"]["Entrypoint"]
                == serde_json::json!([ir["process"]["executable"]]),
        "nix2container native image missing",
    )?;
    check(
        json(directory.join("oci-layout"))?["imageLayoutVersion"] == "1.0.0",
        "invalid OCI layout",
    )?;
    let index = json(directory.join("index.json"))?;
    check(
        index["schemaVersion"] == 2 && array(&index["manifests"]).len() == 1,
        "invalid OCI index",
    )?;
    let reference = &index["manifests"][0];
    let mut reached = BTreeSet::new();
    let manifest: Value = serde_json::from_slice(&blob(directory, reference, &mut reached)?)?;
    let config: Value =
        serde_json::from_slice(&blob(directory, &manifest["config"], &mut reached)?)?;
    let mut nodes = BTreeMap::new();
    let mut diff_ids = Vec::new();
    for layer_ref in array(&manifest["layers"]) {
        diff_ids.push(layer(
            blob(directory, layer_ref, &mut reached)?,
            text(&layer_ref["mediaType"]),
            &mut nodes,
        )?);
    }
    check(
        config["rootfs"] == serde_json::json!({"type":"layers","diff_ids":diff_ids}),
        "OCI DiffIDs differ",
    )?;
    verify_config(&config, &ir)?;
    let files: BTreeSet<String> = std::fs::read_dir(directory.join("blobs/sha256"))?
        .map(|p| p.map(|p| p.file_name().to_string_lossy().into_owned()))
        .collect::<std::io::Result<_>>()?;
    check(files == reached, "extra unreferenced OCI blobs")?;
    verify_filesystem(&nodes, &descriptor, &manifest_bytes, &descriptor_bytes)?;
    let provenance = json(directory.join("provenance.json"))?;
    check(
        provenance["schemaVersion"] == 1
            && provenance["adapterVersion"] == 1
            && provenance["backend"] == "nix2container",
        "unversioned image provenance",
    )?;
    check(
        provenance["billetManifestDigest"] == descriptor["manifestDigest"]
            && provenance["imageManifestDigest"] == reference["digest"]
            && text(&provenance["closureDescriptorDigest"]) == digest(&descriptor_bytes),
        "image provenance identity differs",
    )?;
    check(
        provenance["backendRevision"]
            == config["config"]["Labels"]["org.actionable-work.billet.nix2container-revision"],
        "backend revision unbound",
    )?;
    check(
        std::fs::read_to_string(directory.join("image-digest"))?.trim()
            == text(&reference["digest"]),
        "image digest record differs",
    )?;
    verify_exports(directory)?;
    println!(
        "nix2container OCI config, {} runtime paths, all filesystem bytes and two independent exports verified",
        array(&descriptor["paths"]).len()
    );
    Ok(())
}

fn verify_config(config: &Value, ir: &Value) -> Result {
    let architecture = match text(&ir["system"]) {
        "x86_64-linux" => "amd64",
        "aarch64-linux" => "arm64",
        _ => return Err("unsupported image system".into()),
    };
    check(
        config["os"] == "linux"
            && config["architecture"] == architecture
            && config["created"] == "1970-01-01T00:00:00Z",
        "image platform/time differs",
    )?;
    let runtime = &config["config"];
    let process = &ir["process"];
    let environment: Vec<String> = process["environment"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(k, v)| format!("{k}={}", text(v)))
        .collect();
    check(
        runtime["Entrypoint"] == serde_json::json!([process["executable"]])
            && runtime["Cmd"] == process["argv"]
            && runtime["Env"] == serde_json::json!(environment),
        "image argv/environment changed",
    )?;
    check(
        runtime["User"] == process["user"]
            && runtime["WorkingDir"] == process["workingDirectory"]
            && runtime["StopSignal"] == ir["shutdown"]["stopSignal"],
        "process configuration changed",
    )?;
    check(
        runtime["Volumes"].is_null()
            && runtime["Healthcheck"].is_null()
            && !environment.iter().any(|v| v.starts_with("APP_TOKEN=")),
        "image silently injected runtime semantics",
    )?;
    Ok(())
}

fn verify_filesystem(
    nodes: &BTreeMap<String, Node>,
    descriptor: &Value,
    manifest: &[u8],
    closure: &[u8],
) -> Result {
    check(
        nodes
            .get("etc/billet/manifest.json")
            .ok_or("missing manifest")?
            .bytes
            == manifest
            && nodes
                .get("etc/billet/closure.json")
                .ok_or("missing descriptor")?
                .bytes
                == closure,
        "bundled metadata differs",
    )?;
    let mut expected: BTreeSet<String> = [
        "nix",
        "nix/store",
        "etc",
        "etc/billet",
        "etc/billet/manifest.json",
        "etc/billet/closure.json",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect();
    if nodes.contains_key("") {
        expected.insert(String::new());
    }
    for node in array(&descriptor["paths"]) {
        tree(Path::new(text(&node["path"])), nodes, &mut expected)?;
    }
    check(
        nodes.keys().cloned().collect::<BTreeSet<_>>() == expected,
        "unrelated image store/build-tool paths",
    )?;
    check(
        !nodes.values().any(|node| {
            node.bytes
                .windows(b"DO-NOT-ECHO-SECRET".len())
                .any(|bytes| bytes == b"DO-NOT-ECHO-SECRET")
        }),
        "secret canary in image",
    )
}

fn verify_exports(original: &Path) -> Result {
    let temporary = Temporary::new()?;
    for name in ["first", "second"] {
        let destination = temporary.0.join(name);
        invoke(
            &env("imageExporter"),
            &[
                "--format",
                "oci",
                &format!("oci:{}:billet", destination.display()),
            ],
        )?;
        compare_export(original, &destination)?;
    }
    Ok(())
}

fn compare_export(original: &Path, repeated: &Path) -> Result {
    check(
        export_names(original)? == export_names(repeated)?,
        "nix2container export file inventory changed",
    )?;
    for entry in std::fs::read_dir(repeated)? {
        let entry = entry?;
        let name = entry.file_name();
        let original = original.join(&name);
        if entry.file_type()?.is_dir() {
            compare_export(&original, &entry.path())?;
        } else {
            check(
                digest(&std::fs::read(original)?) == digest(&std::fs::read(entry.path())?),
                "nix2container export changed bytes",
            )?;
        }
    }
    Ok(())
}

fn export_names(directory: &Path) -> Result<BTreeSet<std::ffi::OsString>> {
    let mut names = BTreeSet::new();
    for entry in std::fs::read_dir(directory)? {
        let name = entry?.file_name();
        if name != "provenance.json" && name != "image-digest" {
            names.insert(name);
        }
    }
    Ok(names)
}
