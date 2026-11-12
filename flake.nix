{
  description = "Billet: portable Nix application contracts and runtime closures";

  inputs = {
    bloomery.url = "github:actionable-work/bloomery";
    nixpkgs.follows = "bloomery/nixpkgs";
    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    nixpkgs,
    bloomery,
    nix2container,
    ...
  }: let
    billetLib = import ./lib {
      lib = nixpkgs.lib;
      inherit nix2container;
    };
  in
    bloomery.mkFlake {
      inherit nixpkgs;
      root = ./.;
      extraOutputs = {
        eachSystem,
        perSystemWorkspace,
      }: let
        examples = eachSystem (system: {
          hello = billetLib.mkBillet {
            pkgs = nixpkgs.legacyPackages.${system};
            modules = [./examples/hello.nix];
          };
        });
      in {
        lib = billetLib;
        billets = examples;
        apps = eachSystem (system:
          perSystemWorkspace.${system}.apps
          // {
            example = {
              type = "app";
              program = examples.${system}.hello.ir.process.executable;
            };
            oci-smoke = let
              pkgs = nixpkgs.legacyPackages.${system};
              smoke = pkgs.writeShellApplication {
                name = "billet-oci-smoke";
                runtimeInputs = [pkgs.docker-client nix2container.packages.${system}.skopeo-nix2container];
                text = ''exec ${perSystemWorkspace.${system}.packages.billet-acceptance}/bin/billet-acceptance smoke "$@"'';
              };
            in {
              type = "app";
              program = "${smoke}/bin/billet-oci-smoke";
            };
          });
        checks = eachSystem (system:
          (import ./tests/acceptance.test.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            inherit billetLib;
            cli = perSystemWorkspace.${system}.packages.billet;
            harness = perSystemWorkspace.${system}.packages.billet-acceptance;
          })
          // (import ./tests/oci.test.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            inherit billetLib;
            harness = perSystemWorkspace.${system}.packages.billet-acceptance;
          }));
      };
    };
}
