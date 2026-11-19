{
  description = "Compose artifacts for a Bloomery Rust catalog and its report client";

  inputs = {
    billet = {
      url = "path:../..";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    bloomery.url = "github:actionable-work/bloomery";
    nixpkgs.follows = "bloomery/nixpkgs";
  };

  outputs = {
    billet,
    bloomery,
    nixpkgs,
    ...
  }:
    bloomery.mkFlake {
      inherit nixpkgs;
      root = ./.;
      billets = import ./billets.nix {billetLib = billet.lib;};
    };
}
