{
  pkgs,
  qualificationChecks,
  smoke,
  publicFormatter,
}: let
  inherit (pkgs) lib;
  publicFlake = import ../flake.nix;
  publicOutputs = publicFlake.outputs {
    self = {};
    nixpkgs = {inherit lib;};
    nix2container = {};
    microvm = {};
    treefmt-nix = {};
  };
  publicSystems = ["aarch64-darwin" "aarch64-linux" "x86_64-linux"];
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  publicInputs = ["microvm" "nix2container" "nixpkgs" "treefmt-nix"];
in {
  "billet:public-flake" = assert builtins.attrNames publicFlake.inputs == publicInputs;
  assert builtins.attrNames lock.nodes.${lock.root}.inputs == publicInputs;
  assert builtins.attrNames publicOutputs == ["checks" "formatter" "lib"];
  assert lib.all (name: builtins.isFunction publicOutputs.lib.${name}) ["mkBillet" "mkBilletBundle"];
  assert lib.isDerivation qualificationChecks."billet:compose-preflight";
  assert lib.isDerivation qualificationChecks."billet:closure-acceptance";
  assert smoke.type == "app" && lib.hasSuffix "/bin/billet-oci-smoke" smoke.program;
    pkgs.runCommand "billet-public-flake" {
      passthru.bloomery = ["BILLET-PUBLIC-BUILD-004" "BILLET-PUBLIC-BUILD-005" "BILLET-PUBLIC-BUILD-007"];
    } ''touch "$out"'';
  "billet:public-formatter" = assert builtins.attrNames publicFormatter == publicSystems;
  assert lib.all (system: lib.isDerivation publicFormatter.${system}) publicSystems;
    pkgs.runCommand "billet-public-formatter" {
      passthru.bloomery = ["BILLET-PUBLIC-BUILD-010"];
    } ''touch "$out"'';
}
