{
  pkgs,
  billetLib,
  harness,
  microvmSource,
}: let
  inherit (pkgs) lib;
  hello = ../examples/hello/application.nix;
  darwin = billetLib.mkBillet {
    pkgs = import pkgs.path {system = "aarch64-darwin";};
    modules = [hello];
  };
  # The other supported Linux system, evaluated from this builder.
  foreignSystem =
    if pkgs.stdenv.hostPlatform.system == "aarch64-linux"
    then "x86_64-linux"
    else "aarch64-linux";
  # A TCG guest for each supported Linux system, evaluated on every builder.
  tcg = system:
    (billetLib.mkBillet {
      pkgs = import pkgs.path {inherit system;};
      modules = [
        hello
        {microvm.acceleration = "tcg";}
      ];
    })
    .microvm;
  foreign = tcg foreignSystem;
  emulates = system: machineOpts: kernelModules: let
    inherit (tcg system) configuration;
  in
    configuration.microvm.qemu.machineOpts
    == machineOpts
    && configuration.microvm.cpu == "max"
    && configuration.boot.kernelModules == kernelModules;
  refused = report: code:
    report.system
    == "aarch64-darwin"
    && builtins.any (d: d.code == code && d.field == "systems" && (d.severity or "error") == "error") report.diagnostics;
  assertions = {
    "TARGETS-086" =
      darwin.ir.system
      == "aarch64-darwin"
      && darwin.manifestDigest == "sha256:${builtins.hashString "sha256" darwin.canonicalJSON}";
    "TARGETS-087" = let
      reports = [darwin.dockerCompose.capabilityReport darwin.kubernetes.capabilityReport darwin.microvm.capabilityReport];
    in
      builtins.all (report: !report.canRender && report.supportedCapabilities == []) reports
      && !darwin.kubernetes.capabilityReport.image.supported
      && refused darwin.kubernetes.capabilityReport.image "UnsupportedImageSystem"
      && refused darwin.dockerCompose.capabilityReport "UnsupportedImageSystem"
      && refused darwin.kubernetes.capabilityReport "UnsupportedImageSystem"
      && refused darwin.microvm.capabilityReport "UnsupportedMicrovmSystem";
    "MICROVM-088" = let
      inherit (foreign) runner capabilityReport;
    in
      capabilityReport.canRender
      && foreignSystem != pkgs.stdenv.hostPlatform.system
      && capabilityReport.system == foreignSystem
      && runner.system == foreignSystem
      && lib.hasSuffix ".drv" (builtins.unsafeDiscardStringContext runner.drvPath);
    "MICROVM-089" = emulates "aarch64-linux" {
      accel = "tcg";
      gic-version = "max";
    } ["evdev"];
    "MICROVM-090" = emulates "x86_64-linux" {
      accel = "tcg";
      acpi = "on";
    } ["evdev" "button"];
  };
  qualification.passthru.bloomery = [
    "BILLET-IR-MICROVM-088"
    "BILLET-IR-MICROVM-089"
    "BILLET-IR-MICROVM-090"
    "BILLET-IR-TARGETS-086"
    "BILLET-IR-TARGETS-087"
  ];
in {
  "billet:cross-system-evaluation" = assert qualification.passthru.bloomery == map (key: "BILLET-IR-${key}") (builtins.attrNames assertions);
  assert lib.foldlAttrs (ok: key: passed:
    if passed
    then ok
    else throw "cross-system assertion ${key} failed")
  true
  assertions;
    pkgs.runCommand "billet-cross-system-evaluation" qualification "touch $out";

  "billet:cross-system-diagnostics" =
    pkgs.runCommand "billet-cross-system-diagnostics" {
      passthru.bloomery = [
        "BILLET-IR-TARGETS-088"
        "BILLET-IR-TARGETS-089"
        "BILLET-IR-TARGETS-090"
        "BILLET-IR-TARGETS-091"
      ];
      nativeBuildInputs = [pkgs.nix];
      source = ../.;
      nixpkgsSource = pkgs.path;
      inherit microvmSource;
    } ''
      ${harness}/bin/billet-acceptance systems
      touch "$out"
    '';
}
