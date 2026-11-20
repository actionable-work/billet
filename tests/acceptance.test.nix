{
  pkgs,
  billetLib,
  cli,
  harness,
}: let
  inherit (pkgs) lib;
  fixtures = import ./fixtures.nix {inherit pkgs billetLib;};
  inherit (fixtures) evaluate sample;
  base = evaluate fixtures.base;
  reordered = evaluate (lib.recursiveUpdate fixtures.full {
    resources.placement = ["zone-a" "zone-b"];
    requiredCapabilities = ["fixture-extra"];
  });
  explicit = evaluate (lib.recursiveUpdate fixtures.base {
    schemaVersion = 1;
    restart = {
      enabled = true;
      maxRetries = 5;
      initialDelaySeconds = 1;
      maxDelaySeconds = 30;
      multiplier = 2;
      jitter = true;
      continuousReadyResetSeconds = 300;
    };
    shutdown = {
      stopSignal = "SIGTERM";
      stopGracePeriodSeconds = 30;
    };
    rollout = {
      strategy = "rolling";
      maxSurge = 1;
      maxUnavailable = 0;
      minReadySeconds = 10;
      progressDeadlineSeconds = 600;
      automaticRollback = true;
    };
  });
  rejected = lib.mapAttrs (_: module: !(builtins.tryEval (builtins.deepSeq (evaluate module).ir true)).success) fixtures.invalid;
  acceptance =
    builtins.deepSeq [
      (assert sample.canonicalJSON == reordered.canonicalJSON; true)
      (assert sample.manifestDigest == reordered.manifestDigest; true)
      (assert base.canonicalJSON == explicit.canonicalJSON; true)
      (assert base.manifestDigest == "sha256:${builtins.hashString "sha256" base.canonicalJSON}"; true)
      (assert sample.ir.process.argv == ["" "two words" "$(not-a-shell)" "a;b"]; true)
      (assert builtins.all (x: x) (builtins.attrValues rejected); true)
      (assert sample.ir.secrets.database.external == "runtime/database"; true)
      (assert !(sample.ir.secrets.database ? value); true)
      (assert sample.ir.restart.maxRetries == 5 && sample.ir.rollout.minReadySeconds == 10; true)
      (assert (evaluate (fixtures.base // {systems = [pkgs.stdenv.hostPlatform.system "aarch64-linux"];})).ir.system == pkgs.stdenv.hostPlatform.system; true)
      (assert builtins.all (node: node.locked.type == "github") (builtins.filter (node: node ? locked) (builtins.attrValues (builtins.fromJSON (builtins.readFile ../flake.lock)).nodes)); true)
    ]
    true;
  failure = name: module: message:
    pkgs.testers.testBuildFailure' {
      name = "billet-${name}";
      drv = (evaluate module).closureDescriptor;
      expectedBuilderLogEntries = [message];
    };
in {
  "billet:missing-executable" = (failure "missing-executable" (lib.recursiveUpdate fixtures.base {
    process.executable = "bin/missing";
  }) "billet: process.executable: executable does not exist").overrideAttrs (_: {passthru.bloomery = ["BILLET-CLOSURE-DESCRIPTOR-007"];});

  "billet:missing-init-executable" = (failure "missing-init-executable" (lib.recursiveUpdate fixtures.full {
    initialization.steps = [(builtins.head fixtures.full.initialization.steps // {executable = "bin/missing";})];
  }) "billet: initialization.steps.0.executable: executable does not exist").overrideAttrs (_: {passthru.bloomery = ["BILLET-CLOSURE-DESCRIPTOR-007"];});

  "billet:missing-probe-executable" = (failure "missing-probe-executable" (lib.recursiveUpdate fixtures.full {
    probes.readiness.command.executable = "bin/missing";
  }) "billet: probes.readiness.command.executable: executable does not exist").overrideAttrs (_: {passthru.bloomery = ["BILLET-CLOSURE-DESCRIPTOR-007"];});

  "billet:escaping-executable" = (failure "escaping-executable" (lib.recursiveUpdate fixtures.base {
    process.package = pkgs.runCommand "billet-escaping-executable" {} ''
      mkdir -p "$out/bin"
      ln -s ${pkgs.hello}/bin/hello "$out/bin/hello"
    '';
  }) "billet: process.executable: executable escapes package output").overrideAttrs (_: {passthru.bloomery = ["BILLET-CLOSURE-DESCRIPTOR-008"];});

  "billet:non-executable" = (failure "non-executable" (lib.recursiveUpdate fixtures.base {
    process.package = pkgs.runCommand "billet-non-executable" {} ''
      mkdir -p "$out/bin"
      echo 'non-executable' > "$out/bin/hello"
    '';
  }) "billet: process.executable: expected executable regular file").overrideAttrs (_: {passthru.bloomery = ["BILLET-CLOSURE-DESCRIPTOR-009"];});

  "billet:cli-acceptance" =
    pkgs.runCommand "billet-cli-acceptance" {
      passthru.bloomery = ["BILLET-CLI-INVOCATION-001" "BILLET-CLI-INVOCATION-003" "BILLET-CLI-INVOCATION-004" "BILLET-CLI-INVOCATION-005" "BILLET-CLI-INVOCATION-006"];
      nativeBuildInputs = [];
      cli = "${cli}/bin/billet";
      testShell = pkgs.runtimeShell;
    } ''
      ${harness}/bin/billet-acceptance cli
      touch "$out"
    '';
  "billet:ir-acceptance" = assert acceptance;
    pkgs.runCommand "billet-ir-acceptance" {
      passthru.bloomery = ["BILLET-IR-NORMALIZATION-001" "BILLET-IR-VALIDATION-001" "BILLET-IR-SECRETS-001" "BILLET-PUBLIC-BUILD-001" "BILLET-PUBLIC-BUILD-002" "BILLET-PUBLIC-BUILD-003" "BILLET-IR-NORMALIZATION-002" "BILLET-IR-NORMALIZATION-003" "BILLET-IR-NORMALIZATION-004" "BILLET-IR-NORMALIZATION-005" "BILLET-IR-NORMALIZATION-006" "BILLET-IR-VALIDATION-002" "BILLET-IR-VALIDATION-003" "BILLET-IR-VALIDATION-004" "BILLET-IR-VALIDATION-005" "BILLET-IR-SECRETS-002" "BILLET-IR-SECRETS-003" "BILLET-IR-SECRETS-004" "BILLET-IR-VALIDATION-006" "BILLET-IR-VALIDATION-007" "BILLET-IR-VALIDATION-008" "BILLET-IR-VALIDATION-009" "BILLET-IR-VALIDATION-010" "BILLET-IR-VALIDATION-011" "BILLET-IR-VALIDATION-012" "BILLET-IR-VALIDATION-013" "BILLET-IR-VALIDATION-014" "BILLET-IR-VALIDATION-015" "BILLET-IR-VALIDATION-016" "BILLET-IR-VALIDATION-017" "BILLET-IR-VALIDATION-018" "BILLET-IR-VALIDATION-019" "BILLET-IR-VALIDATION-020" "BILLET-IR-VALIDATION-021" "BILLET-IR-VALIDATION-022" "BILLET-IR-VALIDATION-023" "BILLET-IR-VALIDATION-024" "BILLET-IR-VALIDATION-025" "BILLET-IR-SECRETS-005" "BILLET-IR-SECRETS-006" "BILLET-IR-SECRETS-007" "BILLET-IR-SECRETS-008" "BILLET-IR-NORMALIZATION-009"];
      nativeBuildInputs = [pkgs.nix];
      source = ../.;
      nixpkgsSource = pkgs.path;
      manifest = sample.manifest;
      baseManifest = base.manifest;
      descriptor = sample.closureDescriptor;
      derivationSpec = pkgs.writeText "billet-derivation-spec.json" (builtins.toJSON sample.closureDescriptor.drvAttrs);
      system = pkgs.stdenv.hostPlatform.system;
    } ''
      ${harness}/bin/billet-acceptance ir
      touch "$out"
    '';
  "billet:rejection-diagnostics" =
    pkgs.runCommand "billet-rejection-diagnostics" {
      passthru.bloomery = ["BILLET-IR-VALIDATION-029" "BILLET-IR-VALIDATION-030" "BILLET-IR-VALIDATION-031"];
      nativeBuildInputs = [pkgs.nix];
      source = ../.;
      nixpkgsSource = pkgs.path;
      system = pkgs.stdenv.hostPlatform.system;
      invalidFixtures = builtins.toJSON (builtins.attrNames fixtures.invalid);
    } ''
      ${harness}/bin/billet-acceptance rejections
      touch "$out"
    '';
  "billet:closure-acceptance" =
    pkgs.runCommand "billet-closure-acceptance" {
      passthru.bloomery = ["BILLET-CLOSURE-DESCRIPTOR-001" "BILLET-IR-SECRETS-001" "BILLET-CLOSURE-DESCRIPTOR-002" "BILLET-CLOSURE-DESCRIPTOR-003" "BILLET-CLOSURE-DESCRIPTOR-004" "BILLET-CLOSURE-DESCRIPTOR-005" "BILLET-CLOSURE-DESCRIPTOR-006"];
      nativeBuildInputs = [pkgs.nix];
      descriptor = sample.closureDescriptor;
      expectedRoots = builtins.toJSON sample.runtimeRoots;
      expectedPaths = builtins.toJSON (map toString [fixtures.app fixtures.middle fixtures.leaf fixtures.data fixtures.initPackage fixtures.probePackage]);
      expectedEdges = builtins.toJSON [
        [(toString fixtures.app) (toString fixtures.middle)]
        [(toString fixtures.middle) (toString fixtures.leaf)]
        [(toString sample.manifest) (toString fixtures.data)]
      ];
      forbiddenPath = toString (pkgs.writeText "billet-unrelated" "not a runtime dependency");
    } ''
      ${harness}/bin/billet-acceptance closure
      touch "$out"
    '';
}
