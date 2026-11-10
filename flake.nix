{
  description = "Billet: portable Nix application contracts and runtime closures";

  inputs = {
    bloomery.url = "github:actionable-work/bloomery";
    nixpkgs.follows = "bloomery/nixpkgs";
  };

  outputs = {
    nixpkgs,
    bloomery,
    ...
  }: let
    billetLib = import ./lib {lib = nixpkgs.lib;};
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
          });
        checks = eachSystem (system:
          import ./tests/acceptance.test.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            inherit billetLib;
            cli = perSystemWorkspace.${system}.packages.billet;
          });
      };
    };
}
