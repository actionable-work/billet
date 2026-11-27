{lib}: ir: let
  protected = ["/nix/store" "/etc/billet/manifest.json" "/etc/billet/closure.json"];
  conflicts = path:
    builtins.any (reserved: path == reserved || lib.hasPrefix "${path}/" reserved || lib.hasPrefix "${reserved}/" path) protected;
  diagnostic = capability: field: {
    inherit capability field;
    code = "ProtectedContainerMount";
    severity = "error";
    reason = "mount overlaps the runtime closure or Billet image metadata";
  };
in
  lib.mapAttrsToList (name: _: diagnostic "runtime-secrets" "secrets.${name}.target")
  (lib.filterAttrs (_: secret: secret.mode == "file" && conflicts secret.target) ir.secrets)
  ++ lib.mapAttrsToList (name: _: diagnostic "storage" "storage.${name}.mountPoint")
  (lib.filterAttrs (_: claim: conflicts claim.mountPoint) ir.storage)
