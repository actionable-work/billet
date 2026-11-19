{
  pkgs,
  microvm,
}: modules:
import (pkgs.path + "/nixos/lib/eval-config.nix") {
  inherit (pkgs) lib;
  system = null;
  modules =
    [
      {nixpkgs.pkgs = pkgs;}
      (microvm.outPath + "/nixos-modules/microvm")
    ]
    ++ modules;
}
