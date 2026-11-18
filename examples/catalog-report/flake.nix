{
  description = "Compose artifacts for a Bloomery Rust catalog and its report client";

  inputs = {
    billet.url = "path:../..";
    bloomery = {
      url = "github:actionable-work/bloomery";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.follows = "billet/nixpkgs";
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
