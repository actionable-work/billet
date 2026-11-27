{
  pkgs,
  billets,
  members,
  system,
  structureDiagnostics,
  linkDiagnostics,
}: let
  inherit (pkgs) lib;
  reports = lib.mapAttrs (_: billet: billet.dockerCompose.capabilityReport) billets;
  project = import ./compose-project.nix {inherit lib;} members;
  memberReports = lib.concatLists (lib.mapAttrsToList (name: report:
    map (item: item // {field = "services.${name}.${item.field}";}) report.diagnostics)
  reports);
  diagnostics = map (item: item // {capability = "compose-packaging";}) structureDiagnostics ++ linkDiagnostics ++ memberReports ++ project.diagnostics;
  sorted = values: lib.sort builtins.lessThan (lib.unique values);
  formatDiagnostics = lib.concatMapStringsSep "; " (item: "${item.field}: ${item.reason}");
  canRender = structureDiagnostics == [] && linkDiagnostics == [] && lib.all (report: report.canRender) (builtins.attrValues reports);
  capabilityReport = {
    schemaVersion = 1;
    target = "dockerCompose";
    profile = "compose-artifact-bundle-v1";
    profileVersion = 1;
    rendererVersion = 1;
    mode = "artifact-only";
    inherit system diagnostics canRender;
    services = reports;
    requiredCapabilities = sorted (lib.concatMap (report: report.requiredCapabilities) (builtins.attrValues reports));
    supportedCapabilities =
      if canRender
      then sorted (lib.concatMap (report: report.supportedCapabilities) (builtins.attrValues reports) ++ project.supportedCapabilities)
      else [];
  };
  renderable =
    capabilityReport.canRender
    || throw ("billet: UnsupportedTarget dockerCompose: " + formatDiagnostics (builtins.filter (item: item.severity == "error") diagnostics));
  configurations = lib.mapAttrs (_: billet: billet.dockerCompose.configuration) billets;
  merge = field: lib.mergeAttrsList (map (config: config.${field} or {}) (builtins.attrValues configurations));
  secrets = merge "secrets";
  volumes = merge "volumes";
  configuration = assert renderable;
    project.configure (lib.mapAttrs (name: config: config.services.${name}) configurations)
    // lib.optionalAttrs (secrets != {}) {inherit secrets;}
    // lib.optionalAttrs (volumes != {}) {inherit volumes;}
    // {
      x-billet.services =
        lib.mapAttrs (name: billet: {
          manifest = "./manifests/${name}.json";
          manifestDigest = builtins.unsafeDiscardStringContext billet.manifestDigest;
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
in {inherit capabilityReport configuration file bundle;}
