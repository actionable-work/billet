//! Rejection and cross-system diagnostics observed through a child evaluator.
use crate::common::*;
use std::collections::BTreeSet;

const CANARY: &str = "DO-NOT-ECHO-SECRET";
const INITIALIZATION_BUDGET: &str = "must contain all step timeouts within startup allowance";
const IMAGE_NAME: &str =
    "must be a lowercase image repository name; set it explicitly when identity.name is not one";

/// The diagnostic each `fixtures.invalid` entry must produce: fixture, field path and reason.
const REJECTIONS: [(&str, &str, &str); 37] = [
    ("cpu", "resources.cpuRequest", "exceeds limit"),
    ("duplicateInit", "initialization.steps.id", "must be unique"),
    ("duplicateSecret", "secrets.target", "must be unique"),
    (
        "executable",
        "process.executable",
        "must be a normalized package-relative executable",
    ),
    (
        "grace",
        "shutdown.stopGracePeriodSeconds",
        "must be nonnegative",
    ),
    ("imageName", "oci.imageName", IMAGE_NAME),
    ("imageNameDefault", "oci.imageName", IMAGE_NAME),
    (
        "initBudget",
        "initialization.budgetSeconds",
        INITIALIZATION_BUDGET,
    ),
    ("inlineSecret", "secrets.database.value", "unknown field"),
    ("memory", "resources.memoryLimit", "must be positive"),
    ("mount", "storage.mountPoint", "mounts overlap"),
    ("multiplier", "restart.multiplier", "must exceed one"),
    ("noPackage", "process.package", "package is required"),
    (
        "ociLayersAboveMaximum",
        "oci.maxLayers",
        "must be in 1..124",
    ),
    (
        "ociLayersBelowMinimum",
        "oci.maxLayers",
        "must be in 1..124",
    ),
    ("ociLayersType", "oci.maxLayers", "expected integer"),
    (
        "overlayConflict",
        "process.environment.GUESTBOOK_LOG_LEVEL",
        "conflicting definitions",
    ),
    (
        "persistentMemory",
        "storage.scratch.medium",
        "memory claims must be ephemeral",
    ),
    ("ports", "network.ports.port", "must be unique"),
    (
        "probePort",
        "probes.readiness.port",
        "must reference a declared port for network probes",
    ),
    (
        "probeType",
        "probes.readiness.command",
        "exec probes require a command; other probes forbid it",
    ),
    ("replicas", "resources.replicas.max", "must be at least min"),
    ("retry", "restart.maxRetries", "must be nonnegative"),
    ("retryDelay", "restart.maxDelaySeconds", "must be positive"),
    (
        "rollout",
        "rollout.progressDeadlineSeconds",
        "must be positive",
    ),
    (
        "rolloutProgress",
        "rollout.maxSurge",
        "rollout requires a progress allowance",
    ),
    (
        "schemaVersion",
        "schemaVersion",
        "unsupported schema version; explicit migration required",
    ),
    (
        "scratch",
        "storage.sizeBytes",
        "memory scratch exceeds memory limit",
    ),
    (
        "scratchOverflow",
        "storage.sizeBytes",
        "memory scratch exceeds memory limit",
    ),
    (
        "secretCollision",
        "secrets.token.target",
        "collides with non-secret environment",
    ),
    (
        "secretContext",
        "secrets.database",
        "references cannot carry store dependencies",
    ),
    (
        "secretMount",
        "secrets.target",
        "file delivery overlaps a storage mount",
    ),
    ("secretType", "secrets.database.external", "expected string"),
    (
        "singleton",
        "resources.strictSingleton",
        "singleton forbids concurrent replicas and positive surge",
    ),
    ("system", "systems", "selected system is not declared"),
    ("unknown", "applications", "unknown field"),
    ("wrongType", "resources.cpuLimit", "expected integer"),
];

/// Require evaluation to fail with `expected` in its error output and without the canary.
fn rejects(expression: &str, expected: &str, subject: &str) -> Result {
    let result = evaluate(expression)?;
    let error = String::from_utf8(result.stderr)?;
    check(
        !result.status.success() && error.contains(expected),
        &format!("{subject}: expected `{expected}`, got:\n{error}"),
    )?;
    check(
        !error.contains(CANARY),
        &format!("{subject}: rejected value leaked to diagnostic"),
    )
}

/// Every invalid fixture fails with exactly its expected field path and reason.
pub fn rejections() -> Result {
    let fixtures: BTreeSet<String> = serde_json::from_str(&env("invalidFixtures"))?;
    let expected: BTreeSet<String> = REJECTIONS
        .iter()
        .map(|(name, _, _)| (*name).to_owned())
        .collect();
    let missing: Vec<&String> = fixtures.difference(&expected).collect();
    let stale: Vec<&String> = expected.difference(&fixtures).collect();
    check(
        missing.is_empty() && stale.is_empty() && expected.len() == REJECTIONS.len(),
        &format!(
            "invalid fixtures without expectations: {missing:?}; expectations without fixtures: {stale:?}"
        ),
    )?;
    let prefix = nix_expression();
    for (name, field, reason) in REJECTIONS {
        rejects(
            &format!("{prefix}(f.evaluate f.invalid.{name}).ir"),
            &format!("billet: {field}: {reason}"),
            name,
        )?;
    }
    println!(
        "{} invalid fixtures failed with their expected value-free diagnostics",
        fixtures.len()
    );
    Ok(())
}

const OCI_SYSTEM: &str = "systems: OCI adapter supports x86_64-linux and aarch64-linux";
const MICROVM_SYSTEM: &str = "systems: the microVM profile supports x86_64-linux and aarch64-linux";

/// Artifact selectors of a darwin Billet and the message prefix each must report.
const SYSTEM_SELECTORS: [(&str, &str, &str); 13] = [
    ("ociImage", "billet: unsupported OCI image: ", OCI_SYSTEM),
    ("ociLayout", "billet: unsupported OCI image: ", OCI_SYSTEM),
    ("dockerImage", "billet: unsupported OCI image: ", OCI_SYSTEM),
    (
        "dockerCompose.configuration",
        "billet: UnsupportedTarget dockerCompose: ",
        OCI_SYSTEM,
    ),
    (
        "dockerCompose.file",
        "billet: UnsupportedTarget dockerCompose: ",
        OCI_SYSTEM,
    ),
    (
        "dockerCompose.bundle",
        "billet: UnsupportedTarget dockerCompose: ",
        OCI_SYSTEM,
    ),
    (
        "kubernetes.configuration",
        "billet: UnsupportedTarget kubernetes: ",
        OCI_SYSTEM,
    ),
    (
        "kubernetes.file",
        "billet: UnsupportedTarget kubernetes: ",
        OCI_SYSTEM,
    ),
    (
        "kubernetes.bundle",
        "billet: UnsupportedTarget kubernetes: ",
        OCI_SYSTEM,
    ),
    ("microvm.configuration", "billet: microvm: ", MICROVM_SYSTEM),
    ("microvm.file", "billet: microvm: ", MICROVM_SYSTEM),
    ("microvm.runner", "billet: microvm: ", MICROVM_SYSTEM),
    ("microvm.bundle", "billet: microvm: ", MICROVM_SYSTEM),
];

/// Linux-only artifact selectors of a darwin Billet fail with their documented diagnostics.
pub fn systems() -> Result {
    let source = env("source");
    let prefix = format!(
        "let pkgs = import {} {{ system = \"aarch64-darwin\"; }}; billetLib = import {source}/lib {{ inherit (pkgs) lib; microvm = {{ outPath = \"{}\"; }}; }}; b = billetLib.mkBillet {{ inherit pkgs; modules = [ {source}/examples/hello/application.nix ]; }}; in ",
        env("nixpkgsSource"),
        env("microvmSource"),
    );
    success(evaluate(&format!("{prefix}b.canonicalJSON"))?)?;
    for (selector, target, reason) in SYSTEM_SELECTORS {
        rejects(
            &format!("{prefix}builtins.toJSON b.{selector}"),
            &format!("{target}{reason}"),
            selector,
        )?;
    }
    println!(
        "darwin IR evaluated and {} Linux-only selectors reported their diagnostics",
        SYSTEM_SELECTORS.len()
    );
    Ok(())
}
