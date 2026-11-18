{
  description = "Billet: Nix application IR and deployment artifacts";

  inputs = {
    bloomery.url = "github:actionable-work/bloomery";
    nixpkgs.follows = "bloomery/nixpkgs";
    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    bloomery,
    nix2container,
    ...
  }: let
    billetLib = import ./lib {
      lib = nixpkgs.lib;
      inherit nix2container;
    };
    flake = bloomery.mkFlake {
      inherit nixpkgs;
      root = ./.;
      self.inputs = inputs // {billet = self;};
      extraOutputs = {eachSystem, ...}: {
        lib = billetLib;
        billets = eachSystem (system: {
          hello = billetLib.mkBillet {
            pkgs = nixpkgs.legacyPackages.${system};
            modules = [./examples/hello.nix];
          };
        });
      };
    };
  in
    flake
    // {
      apps = nixpkgs.lib.mapAttrs (system: apps:
        apps
        // {
          example = {
            type = "app";
            program = flake.billets.${system}.hello.ir.process.executable;
          };
        })
      flake.apps;
    };
}
