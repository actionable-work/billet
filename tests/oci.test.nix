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
  acceptance =
    builtins.deepSeq [
      (assert !reports.trap.canRender; true)
      (assert !(builtins.tryEval trapped.dockerCompose.configuration).success; true)
      (assert !(builtins.tryEval badUser.ociImage).success; true)
    ]
    true;
in
  {
    "billet:compose-preflight" = assert acceptance;
      pkgs.runCommand "billet-compose-preflight" {
        passthru.bloomery = ["BILLET-IR-TARGETS-001"];
        nativeBuildInputs = [pkgs.nix];
        reportsJSON = builtins.unsafeDiscardStringContext (builtins.toJSON reports);
        source = ../.;
        nixpkgsSource = pkgs.path;
        system = pkgs.stdenv.hostPlatform.system;
      } ''
        ${harness}/bin/billet-acceptance preflight
        touch "$out"
      '';
  }
  // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    "billet:oci-acceptance" =
      pkgs.runCommand "billet-oci-acceptance" {
        passthru.bloomery = ["BILLET-CLOSURE-OCI-001" "BILLET-CLOSURE-OCI-002" "BILLET-IR-SECRETS-001"];
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
