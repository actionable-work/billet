{
  pkgs,
  billetLib,
  harness,
}: let
  inherit (pkgs) lib;
  fixtures = import ./fixtures.nix {inherit pkgs billetLib;};
  sample = fixtures.sample;
  targets = import ../lib/targets.nix {inherit lib;};
  trapped = fixtures.evaluate (lib.recursiveUpdate fixtures.base {
    process.package = pkgs.runCommand "billet-preflight-must-not-build" {} "exit 99";
    process.executable = "bin/trap";
  });
  badUser = fixtures.evaluate (lib.recursiveUpdate fixtures.base {process.user = "nobody";});
  reports = {
    full = sample.dockerCompose.capabilityReport;
    trap = trapped.dockerCompose.capabilityReport;
    invalidUser = badUser.dockerCompose.capabilityReport;
    arm = targets.oci {
      ir = sample.ir // {system = "aarch64-linux";};
      inherit (sample) manifestDigest;
      pkgsSystem = "aarch64-linux";
    };
    darwin = targets.oci {
      ir = sample.ir // {system = "aarch64-darwin";};
      inherit (sample) manifestDigest;
      pkgsSystem = "aarch64-darwin";
    };
    mismatch = targets.oci {
      inherit (sample) ir manifestDigest;
      pkgsSystem = "aarch64-linux";
    };
  };
  supported = pkgs.stdenv.hostPlatform.isLinux;
  registration = (builtins.fromTOML (builtins.readFile ../.bloomery/config.toml)).flakes.tests;
  acceptance = assert registration.path == "tests" && registration.checks == "individual" && registration.apps;
  assert reports.trap.canRender == supported;
  assert reports.full.requiredCapabilities == sample.ir.requiredCapabilities;
  assert !(builtins.tryEval badUser.ociImage).success;
  assert !(builtins.tryEval badUser.dockerCompose.configuration).success;
  assert !supported || !builtins.hasContext (builtins.toJSON trapped.dockerCompose.configuration); true;
in
  {
    "billet:compose-preflight" = assert acceptance;
      pkgs.runCommand "billet-compose-preflight" {
        passthru.bloomery = ["BILLET-IR-TARGETS-001" "BILLET-IR-TARGETS-002" "BILLET-IR-TARGETS-003" "BILLET-IR-TARGETS-004" "BILLET-IR-TARGETS-005" "BILLET-PUBLIC-BUILD-004"];
        nativeBuildInputs = [pkgs.nix];
        reportsJSON = builtins.unsafeDiscardStringContext (builtins.toJSON reports);
        source = ../.;
        nixpkgsSource = pkgs.path;
        system = pkgs.stdenv.hostPlatform.system;
        trapConfiguration =
          if supported
          then trapped.dockerCompose.file
          else "";
      } ''
        if [ -n "$trapConfiguration" ]; then test -s "$trapConfiguration"; fi
        ${harness}/bin/billet-acceptance preflight
        touch "$out"
      '';
  }
  // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    "billet:oci-acceptance" =
      pkgs.runCommand "billet-oci-acceptance" {
        passthru.bloomery = ["BILLET-CLOSURE-OCI-001" "BILLET-CLOSURE-OCI-002" "BILLET-IR-SECRETS-001" "BILLET-IR-SECRETS-004" "BILLET-CLOSURE-OCI-003" "BILLET-CLOSURE-OCI-004" "BILLET-CLOSURE-OCI-005" "BILLET-CLOSURE-OCI-006" "BILLET-CLOSURE-OCI-007" "BILLET-CLOSURE-OCI-008" "BILLET-CLOSURE-OCI-009" "BILLET-CLOSURE-OCI-010" "BILLET-CLOSURE-OCI-011" "BILLET-CLOSURE-OCI-012" "BILLET-CLOSURE-OCI-013"];
        nativeBuildInputs = [];
        image = sample.ociLayout;
        nativeImage = sample.ociImage;
        descriptor = sample.closureDescriptor;
        imageExporter = lib.getExe sample.ociImage.copyTo;
        system = pkgs.stdenv.hostPlatform.system;
      } ''
        ${harness}/bin/billet-acceptance oci
        touch "$out"
      '';
  }
