"""Acceptance checks over real evaluated and built Billet artifacts."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def check_ir():
    source = Path(os.environ["source"])
    expression = f'''let
      pkgs = import {os.environ['nixpkgsSource']} {{ system = "{os.environ['system']}"; }};
      billetLib = import {source}/lib {{ inherit (pkgs) lib; }};
      f = import {source}/tests/fixtures.nix {{ inherit pkgs billetLib; }};
    in '''
    cases = {
        "wrongType": "resources.cpuLimit",
        "inlineSecret": "secrets.database.value",
        "secretType": "secrets.database.external",
        "unknown": "applications",
        "probePort": "probes.readiness.port",
        "mount": "storage.mountPoint",
        "schemaVersion": "schemaVersion",
    }
    for name, field in cases.items():
        result = subprocess.run(
            ["nix-instantiate", "--store", "dummy://", "--eval", "--strict", "--json", "--expr",
             expression + f"(f.evaluate f.invalid.{name}).ir"],
            capture_output=True, text=True, check=False,
        )
        assert result.returncode != 0, name
        assert f"billet: {field}:" in result.stderr, result.stderr
        assert "DO-NOT-ECHO-SECRET" not in result.stderr, result.stderr
    repeated = []
    for _ in range(2):
        result = subprocess.run(
            ["nix-instantiate", "--store", "dummy://", "--eval", "--strict", "--json", "--expr",
             expression + "f.sample.canonicalJSON"], capture_output=True, check=True,
        )
        repeated.append(json.loads(result.stdout).encode())
    payload = Path(os.environ["manifest"]).read_bytes()
    assert repeated == [payload, payload]
    base = json.loads(Path(os.environ["baseManifest"]).read_bytes())
    golden = (source / "tests/golden/hello-v1.json").read_bytes()
    canonical_base = Path(os.environ["baseManifest"]).read_bytes()
    symbolic = canonical_base.replace(base["process"]["package"].encode(), b"@PACKAGE@")
    symbolic = symbolic.replace(base["system"].encode(), b"@SYSTEM@")
    assert symbolic == golden, "v1 normalization changed: explicit version/migration required"
    result = subprocess.run([base["process"]["executable"], *base["process"]["argv"]], capture_output=True, check=True)
    assert result.stdout == b"Hello from Billet\n"
    ir = json.loads(payload)
    assert not payload.endswith(b"\n")
    assert ir["schemaVersion"] == 1 and ir["normalizationVersion"] == 1
    assert ir["process"]["argv"] == ["", "two words", "$(not-a-shell)", "a;b"]
    assert ir["restart"]["maxRetries"] == 5
    assert ir["shutdown"]["stopGracePeriodSeconds"] == 30
    assert ir["rollout"]["progressDeadlineSeconds"] == 600
    assert ir["rollout"]["automaticRollback"] is True
    assert ir["secrets"]["database"] == {
        "external": "runtime/database", "mode": "file",
        "required": True, "target": "/run/secrets/database",
    }
    for path in Path(os.environ["descriptor"]).iterdir():
        assert b"DO-NOT-ECHO-SECRET" not in path.read_bytes()
    derivation = Path(os.environ["derivationSpec"]).read_bytes()
    assert b"DO-NOT-ECHO-SECRET" not in derivation
    assert b"runtime/database" in derivation and b"runtime/token" in derivation
    print(f"Validated canonical IR, {len(cases)} field diagnostics and secret-reference artifacts")


def check_closure():
    directory = Path(os.environ["descriptor"])
    descriptor = json.loads((directory / "descriptor.json").read_text())
    payload = (directory / "manifest.json").read_bytes()
    assert descriptor["schemaVersion"] == 1
    assert descriptor["manifestDigest"] == "sha256:" + hashlib.sha256(payload).hexdigest()
    assert descriptor["system"] == json.loads(payload)["system"]
    assert descriptor["roots"] == sorted(json.loads(os.environ["expectedRoots"]))
    paths = descriptor["paths"]
    by_path = {p["path"]: p for p in paths}
    assert len(by_path) == len(paths)
    assert list(by_path) == sorted(by_path)
    assert set(json.loads(os.environ["expectedPaths"])) <= by_path.keys()
    for source, target in json.loads(os.environ["expectedEdges"]):
        assert target in by_path[source]["references"], (source, target)
    assert os.environ["forbiddenPath"] not in by_path
    reached = set()
    pending = list(descriptor["roots"])
    while pending:
        path = pending.pop()
        if path in reached:
            continue
        reached.add(path)
        node = by_path[path]
        assert node["references"] == sorted(set(node["references"]))
        assert node["narSize"] > 0
        assert node["narHash"].startswith("sha256:")
        pending.extend(node["references"])
        # Independently hash actual NAR bytes, rather than trust descriptor strings.
        nar = subprocess.run(["nix-store", "--dump", path], capture_output=True, check=True).stdout
        assert len(nar) == node["narSize"]
        digest = subprocess.run(["nix-hash", "--type", "sha256", "--base32", "--flat", "/dev/stdin"], input=nar, capture_output=True, check=True).stdout.decode().strip()
        assert node["narHash"] == "sha256:" + digest
    assert reached == by_path.keys(), "extra or unreachable closure paths"
    print(f"Validated {len(paths)} runtime paths, full transitive edges and actual NAR identities")


def check_cli():
    cli = os.environ["cli"]
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        fake_nix = directory / "nix"
        captured = directory / "arguments.json"
        fake_nix.write_text(f"#!{sys.executable}\nimport json, os, sys\n"
                            "open(os.environ['NIX_ARGUMENTS'], 'w').write(json.dumps(sys.argv[1:]))\n"
                            "sys.exit(37)\n")
        fake_nix.chmod(0o755)
        env = dict(os.environ, PATH=str(directory), NIX_ARGUMENTS=str(captured))
        installable = "path:/tmp/space here#billets.x.hello;$(no-shell)"
        for action, prefix, suffix in [
            ("validate", ["eval", "--json"], "ir"),
            ("manifest", ["eval", "--raw"], "canonicalJSON"),
            ("closure", ["build", "--no-link", "--print-out-paths"], "closureDescriptor"),
        ]:
            result = subprocess.run([cli, action, installable], env=env, check=False)
            assert result.returncode == 37
            assert json.loads(captured.read_text()) == prefix + [installable + "." + suffix]
        captured.unlink()
        assert subprocess.run([cli, "validate", "--impure"], env=env, check=False).returncode == 2
        assert not captured.exists()
        fake_nix.unlink()
        assert subprocess.run([cli, "validate", installable], env=env, check=False).returncode == 1
    print("Validated CLI argv, child exits, invalid usage and spawn failure")


if __name__ == "__main__":
    {"ir": check_ir, "closure": check_closure, "cli": check_cli}[sys.argv[1]]()
