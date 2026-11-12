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
  "billet:missing-executable" = failure "missing-executable" (lib.recursiveUpdate fixtures.base {
    process.executable = "bin/missing";
  }) "billet: process.executable: executable does not exist";
  "billet:missing-init-executable" = failure "missing-init-executable" (lib.recursiveUpdate fixtures.full {
    initialization.steps = [(builtins.head fixtures.full.initialization.steps // {executable = "bin/missing";})];
  }) "billet: initialization.steps.0.executable: executable does not exist";
  "billet:missing-probe-executable" = failure "missing-probe-executable" (lib.recursiveUpdate fixtures.full {
    probes.readiness.command.executable = "bin/missing";
  }) "billet: probes.readiness.command.executable: executable does not exist";
  "billet:escaping-executable" = failure "escaping-executable" (lib.recursiveUpdate fixtures.base {
    process.package = pkgs.runCommand "billet-escaping-executable" {} ''
      mkdir -p "$out/bin"
      ln -s ${pkgs.hello}/bin/hello "$out/bin/hello"
    '';
  }) "billet: process.executable: executable escapes package output";
  "billet:non-executable" = failure "non-executable" (lib.recursiveUpdate fixtures.base {
    process.package = pkgs.runCommand "billet-non-executable" {} ''
      mkdir -p "$out/bin"
      echo 'non-executable' > "$out/bin/hello"
    '';
  }) "billet: process.executable: expected executable regular file";
  "billet:cli-acceptance" =
    pkgs.runCommand "billet-cli-acceptance" {
      passthru.bloomery = ["BILLET-CLI-INVOCATION-001"];
      nativeBuildInputs = [];
      cli = "${cli}/bin/billet";
      testShell = pkgs.runtimeShell;
    } ''
      ${harness}/bin/billet-acceptance cli
      touch "$out"
    '';
  "billet:ir-acceptance" = assert acceptance;
    pkgs.runCommand "billet-ir-acceptance" {
      passthru.bloomery = ["BILLET-IR-NORMALIZATION-001" "BILLET-IR-VALIDATION-001" "BILLET-IR-SECRETS-001" "BILLET-PUBLIC-BUILD-001"];
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
  "billet:closure-acceptance" =
    pkgs.runCommand "billet-closure-acceptance" {
      passthru.bloomery = ["BILLET-CLOSURE-DESCRIPTOR-001" "BILLET-IR-SECRETS-001"];
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
