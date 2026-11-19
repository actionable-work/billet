{
  description = "Billet: Nix application IR and deployment artifacts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      # The QEMU guest module uses the caller's package set directly.
      flake = false;
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    nix2container,
    microvm,
    treefmt-nix,
    ...
  }: let
    eachSystem = nixpkgs.lib.genAttrs ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
    treefmt = eachSystem (system: treefmt-nix.lib.evalModule nixpkgs.legacyPackages.${system} ./treefmt.nix);
  in {
    lib = import ./lib {
      lib = nixpkgs.lib;
      inherit nix2container microvm;
    };
    formatter = eachSystem (system: treefmt.${system}.config.build.wrapper);
    checks = eachSystem (system: {
      formatting = treefmt.${system}.config.build.check self;
    });
  };
}
