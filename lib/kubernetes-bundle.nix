{
  pkgs,
  billets,
  system,
  structureDiagnostics,
  linkDiagnostics,
  ...
}: let
  inherit (pkgs) lib;
  services = lib.mapAttrs (_: billet: billet.kubernetes.capabilityReport) billets;
  memberReports = builtins.attrValues services;
  formatDiagnostics = lib.concatMapStringsSep "; " (item: "${item.field}: ${item.reason}");
  error = code: field: reason: {inherit code field reason;};
  preflightOK = structureDiagnostics == [] && linkDiagnostics == [] && builtins.all (report: report.canRender) memberReports;
  resources = lib.optionals preflightOK (lib.concatMap (billet: billet.kubernetes.configuration.items) (builtins.attrValues billets));
  namespaceItems = lib.unique (builtins.filter (item: item.kind == "Namespace") resources);
  namespacedItems = builtins.filter (item: item.kind != "Namespace") resources;
  explicitNamespaces = lib.unique (lib.catAttrs "namespace" (map (item: item.metadata) namespacedItems));
  namespace = builtins.head (explicitNamespaces ++ [null]);
  workloadItems = map (item:
    if namespace == null
    then item
    else item // {metadata = item.metadata // {inherit namespace;};})
  namespacedItems;
  resourceKeys = map (item: [item.apiVersion item.kind item.metadata.name]) workloadItems;
  errors = map (item:
    item
    // {
      severity = "error";
      capability = "kubernetes-packaging";
    }) (
    structureDiagnostics
    ++ lib.optional (builtins.length explicitNamespaces > 1)
    (error "KubernetesBundleNamespaces" "services" "bundle members must share one namespace")
    ++ lib.optional (builtins.length resourceKeys != builtins.length (lib.unique resourceKeys))
    (error "KubernetesBundleResourceCollision" "services" "rendered resources must have distinct identities within the bundle namespace")
  );
  diagnostics =
    errors
    ++ linkDiagnostics
    ++ lib.concatLists (lib.mapAttrsToList (name: report:
      map (item: item // {field = "services.${name}.${item.field}";}) report.diagnostics)
    services);
  canRender = preflightOK && errors == [];
  capabilities = field: lib.sort builtins.lessThan (lib.unique (lib.concatMap (report: report.${field}) memberReports));
  requireRenderable = value:
    if canRender
    then value
    else throw ("billet: UnsupportedTarget kubernetes: " + formatDiagnostics (builtins.filter (item: item.severity == "error") diagnostics));
  configuration = requireRenderable {
    apiVersion = "v1";
    kind = "List";
    items = namespaceItems ++ workloadItems;
  };
  file = requireRenderable (pkgs.writeText "kubernetes.json" (builtins.unsafeDiscardStringContext (builtins.toJSON configuration) + "\n"));
in {
  inherit configuration file;
  capabilityReport = {
    schemaVersion = 1;
    target = "kubernetes";
    profile = "kubernetes-artifact-bundle-v1";
    profileVersion = 1;
    rendererVersion = 1;
    mode = "artifact-only";
    inherit system services diagnostics canRender;
    requiredCapabilities = capabilities "requiredCapabilities";
    supportedCapabilities = lib.optionals canRender (capabilities "supportedCapabilities");
  };
  bundle = requireRenderable (pkgs.runCommand "billet-kubernetes-bundle-v1" {} ''
    mkdir -p "$out/images" "$out/manifests"
    cp ${file} "$out/kubernetes.json"
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: billet: ''
        cp ${billet.dockerImage} "$out/images/${name}.tar"
        cp ${billet.manifest} "$out/manifests/${name}.json"
      '')
      billets)}
  '');
}
