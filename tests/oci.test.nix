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
    identity.name = "trapped";
    process.package = pkgs.runCommand "billet-preflight-must-not-build" {} "exit 99";
    process.executable = "bin/trap";
  });
  badUser = fixtures.evaluate (lib.recursiveUpdate fixtures.base {process.user = "nobody";});
  composeBundle = billets: (billetLib.mkBilletBundle {inherit pkgs billets;}).dockerCompose;
  grouped = composeBundle {
    inherit trapped;
    ${sample.ir.identity.name} = sample;
  };
  otherSystem =
    if pkgs.stdenv.hostPlatform.system == "aarch64-linux"
    then "x86_64-linux"
    else "aarch64-linux";
  foreign = billetLib.mkBillet {
    pkgs = import pkgs.path {system = otherSystem;};
    modules = [../examples/hello/application.nix];
  };
  rejectsBundle = billets: code: field: let
    compose = composeBundle billets;
  in
    !compose.capabilityReport.canRender
    && builtins.any (diagnostic: diagnostic.code == code && diagnostic.field == field) compose.capabilityReport.diagnostics
    && !(builtins.tryEval compose.configuration).success
    && !(builtins.tryEval compose.bundle).success;
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
  acceptance = assert reports.trap.canRender == supported;
  assert reports.full.requiredCapabilities == sample.ir.requiredCapabilities;
  assert !(builtins.tryEval badUser.ociImage).success;
  assert !(builtins.tryEval badUser.dockerCompose.configuration).success;
  assert !supported || !builtins.hasContext (builtins.toJSON trapped.dockerCompose.configuration);
  assert builtins.attrNames grouped == builtins.attrNames sample.dockerCompose;
  assert grouped.capabilityReport.canRender == supported;
  assert grouped.capabilityReport.requiredCapabilities == sample.ir.requiredCapabilities;
  assert !supported || !builtins.hasContext (builtins.toJSON grouped.configuration);
  assert rejectsBundle {} "EmptyBilletBundle" "billets";
  assert rejectsBundle {wrong = sample;} "BundleMemberNameMismatch" "services.wrong.identity.name";
  assert rejectsBundle {hello = foreign;} "BundleMemberSystemMismatch" "services.hello.system";
  assert rejectsBundle {${badUser.ir.identity.name} = badUser;} "UnsupportedImageUser" "services.${badUser.ir.identity.name}.process.user"; true;
in
  {
    "billet:compose-preflight" = assert acceptance;
      pkgs.runCommand "billet-compose-preflight" {
        passthru.bloomery = ["BILLET-IR-TARGETS-001" "BILLET-IR-TARGETS-002" "BILLET-IR-TARGETS-003" "BILLET-IR-TARGETS-004" "BILLET-IR-TARGETS-005" "BILLET-IR-TARGETS-017" "BILLET-IR-TARGETS-018" "BILLET-IR-TARGETS-019" "BILLET-IR-TARGETS-020" "BILLET-IR-TARGETS-021"];
        nativeBuildInputs = [pkgs.nix];
        reportsJSON = builtins.unsafeDiscardStringContext (builtins.toJSON reports);
        source = ../.;
        nixpkgsSource = pkgs.path;
        system = pkgs.stdenv.hostPlatform.system;
        trapConfiguration =
          if supported
          then trapped.dockerCompose.file
          else "";
        trapBundleConfiguration =
          if supported
          then grouped.file
          else "";
      } ''
        if [ -n "$trapConfiguration" ]; then test -s "$trapConfiguration"; fi
        if [ -n "$trapBundleConfiguration" ]; then test -s "$trapBundleConfiguration"; fi
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
