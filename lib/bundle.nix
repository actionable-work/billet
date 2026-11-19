{lib}: {
  pkgs,
  billets,
}: let
  system = pkgs.stdenv.hostPlatform.system;
  members = lib.mapAttrs (_: billet: billet.ir) billets;
  diagnostic = code: field: reason: {inherit code field reason;};
  structureDiagnostics =
    lib.optional (billets == {}) (diagnostic "EmptyBilletBundle" "billets" "provide at least one Billet")
    ++ lib.concatLists (lib.mapAttrsToList (name: ir:
      lib.optional (name != ir.identity.name)
      (diagnostic "BundleMemberNameMismatch" "services.${name}.identity.name" "the member key must match the canonical identity name")
      ++ lib.optional (ir.system != system)
      (diagnostic "BundleMemberSystemMismatch" "services.${name}.system" "the member must match the selected package-set system"))
    members);
  context = {inherit pkgs billets members system structureDiagnostics;};
in {
  inherit billets;
  validationCheck =
    if structureDiagnostics != []
    then throw ("billet: invalid bundle: " + lib.concatMapStringsSep "; " (item: "${item.field}: ${item.reason}") structureDiagnostics)
    else
      builtins.deepSeq members (
        pkgs.writeText "billet-bundle-validation" (
          builtins.unsafeDiscardStringContext (builtins.toJSON (lib.mapAttrs (_: billet: billet.manifestDigest) billets)) + "\n"
        )
      );
  dockerCompose = import ./compose-bundle.nix context;
  kubernetes = import ./kubernetes-bundle.nix context;
}
