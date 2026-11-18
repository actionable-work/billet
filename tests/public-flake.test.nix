{
  pkgs,
  qualificationChecks,
  smoke,
}: let
  inherit (pkgs) lib;
  publicFlake = import ../flake.nix;
  publicOutputs = publicFlake.outputs {
    nixpkgs = {inherit lib;};
    nix2container = {};
  };
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
in {
  "billet:public-flake" = assert builtins.attrNames publicFlake.inputs == ["nix2container" "nixpkgs"];
  assert builtins.attrNames lock.nodes.${lock.root}.inputs == ["nix2container" "nixpkgs"];
  assert builtins.attrNames publicOutputs == ["lib"];
  assert lib.all (name: builtins.isFunction publicOutputs.lib.${name}) ["mkBillet" "mkBilletBundle"];
  assert lib.isDerivation qualificationChecks."billet:compose-preflight";
  assert lib.isDerivation qualificationChecks."billet:closure-acceptance";
  assert smoke.type == "app" && lib.hasSuffix "/bin/billet-oci-smoke" smoke.program;
    pkgs.runCommand "billet-public-flake" {
      passthru.bloomery = ["BILLET-PUBLIC-BUILD-004" "BILLET-PUBLIC-BUILD-005" "BILLET-PUBLIC-BUILD-007"];
    } ''touch "$out"'';
}
