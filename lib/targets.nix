{lib}: {
  oci = {
    ir,
    manifestDigest,
    pkgsSystem,
  }: let
    architectures = {
      x86_64-linux = "amd64";
      aarch64-linux = "arm64";
    };
    diagnostic = code: field: reason: {
      inherit code field reason;
      capability = "oci-packaging";
    };
    numericUser = builtins.match "(0|[1-9][0-9]*):(0|[1-9][0-9]*)" ir.process.user != null;
    validUser =
      numericUser
      && builtins.all (
        part:
          builtins.stringLength part <= 10 && builtins.fromJSON part < 4294967295
      ) (lib.splitString ":" ir.process.user);
    diagnostics =
      lib.optional (ir.schemaVersion != 1 || ir.normalizationVersion != 1)
      (diagnostic "UnsupportedSchemaVersion" "schemaVersion" "OCI adapter requires Billet IR and normalization v1")
      ++ lib.optional (!(builtins.hasAttr ir.system architectures))
      (diagnostic "UnsupportedImageSystem" "systems" "OCI adapter supports x86_64-linux and aarch64-linux")
      ++ lib.optional (ir.system != pkgsSystem)
      (diagnostic "ImageSystemMismatch" "system" "image builder and Billet systems must match")
      ++ lib.optional (!validUser)
      (diagnostic "UnsupportedImageUser" "process.user" "image user must be numeric uid:gid below the reserved unsigned 32-bit maximum");
  in {
    schemaVersion = 1;
    adapterVersion = 1;
    mode = "artifact-only";
    system = ir.system;
    inherit manifestDigest diagnostics;
    supported = diagnostics == [];
    architecture = architectures.${ir.system} or null;
  };
  compose = {
    ir,
    manifestDigest,
    image,
    mapping,
  }: let
    canRender = image.supported && lib.all (item: (item.severity or "warning") != "error") mapping.diagnostics;
  in {
    schemaVersion = 1;
    target = "dockerCompose";
    profile = "compose-artifact-v1";
    profileVersion = 1;
    rendererVersion = 1;
    mode = "artifact-only";
    system = ir.system;
    inherit manifestDigest image;
    requiredCapabilities = ir.requiredCapabilities;
    supportedCapabilities =
      if canRender
      then mapping.supportedCapabilities
      else [];
    inherit canRender;
    diagnostics = image.diagnostics ++ mapping.diagnostics;
  };
}
