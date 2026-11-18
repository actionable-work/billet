{lib}: {
  pkgs,
  billets,
}: let
  system = pkgs.stdenv.hostPlatform.system;
  reports = lib.mapAttrs (_: billet: billet.dockerCompose.capabilityReport) billets;
  diagnostic = code: field: reason: {
    inherit code field reason;
    capability = "compose-packaging";
  };
  emptyDiagnostics = lib.optional (billets == {}) (diagnostic "EmptyBilletBundle" "billets" "provide at least one Billet");
  memberDiagnostics = name: billet:
    lib.optional (name != billet.ir.identity.name)
    (diagnostic "BundleMemberNameMismatch" "services.${name}.identity.name" "the member key must match the canonical identity name")
    ++ lib.optional (billet.ir.system != system)
    (diagnostic "BundleMemberSystemMismatch" "services.${name}.system" "the member must match the selected package-set system");
  diagnostics =
    emptyDiagnostics
    ++ lib.concatLists (lib.mapAttrsToList (name: billet:
      memberDiagnostics name billet
      ++ map (item: item // {field = "services.${name}.${item.field}";}) reports.${name}.diagnostics)
    billets);
  structureDiagnostics = emptyDiagnostics ++ lib.concatLists (lib.mapAttrsToList memberDiagnostics billets);
  formatDiagnostics = lib.concatMapStringsSep "; " (item: "${item.field}: ${item.reason}");
  validationCheck =
    if structureDiagnostics != []
    then throw ("billet: invalid bundle: " + formatDiagnostics structureDiagnostics)
    else
      builtins.deepSeq (lib.mapAttrs (_: billet: billet.ir) billets) (
        pkgs.writeText "billet-bundle-validation" (
          builtins.unsafeDiscardStringContext (builtins.toJSON (lib.mapAttrs (_: billet: billet.manifestDigest) billets)) + "\n"
        )
      );
  capabilityReport = {
    schemaVersion = 1;
    target = "dockerCompose";
    profile = "compose-artifact-bundle-v1";
    profileVersion = 1;
    rendererVersion = 1;
    mode = "artifact-only";
    inherit system diagnostics;
    services = reports;
    requiredCapabilities = lib.sort builtins.lessThan (lib.unique (lib.concatMap (report: report.requiredCapabilities) (builtins.attrValues reports)));
    supportedCapabilities = [];
    canRender = diagnostics == [];
  };
  renderable =
    capabilityReport.canRender
    || throw ("billet: UnsupportedTarget dockerCompose: " + formatDiagnostics diagnostics);
  configuration = assert renderable; {
    services = lib.mapAttrs (name: billet: billet.dockerCompose.configuration.services.${name}) billets;
    x-billet.services =
      lib.mapAttrs (name: billet: {
        manifest = "./manifests/${name}.json";
        inherit (billet.dockerCompose.configuration.x-billet) manifestDigest;
      })
      billets;
  };
  file = assert renderable; pkgs.writeText "compose.yaml" (builtins.toJSON configuration + "\n");
  bundle = assert renderable;
    pkgs.runCommand "billet-docker-compose-bundle-v1" {} ''
      mkdir -p "$out/images" "$out/manifests"
      cp ${file} "$out/compose.yaml"
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: billet: ''
          cp ${billet.dockerImage} "$out/images/${name}.tar"
          cp ${billet.manifest} "$out/manifests/${name}.json"
        '')
        billets)}
    '';
in {
  inherit billets validationCheck;
  dockerCompose = {inherit capabilityReport configuration file bundle;};
}
