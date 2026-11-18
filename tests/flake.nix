{
  description = "Billet artifact qualification";

  inputs = {
    billet.url = "path:..";
    bloomery = {
      url = "github:actionable-work/bloomery";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.follows = "billet/nixpkgs";
    nix2container.follows = "billet/nix2container";
  };

  outputs = {
    self,
    billet,
    bloomery,
    nixpkgs,
    nix2container,
    ...
  }: let
    billetLib = billet.lib;
    hello = (import ../examples/hello/flake.nix).outputs {inherit billet nixpkgs;};
    catalog = (import ../examples/catalog-report/flake.nix).outputs {inherit billet bloomery nixpkgs;};
  in
    bloomery.mkFlake {
      inherit nixpkgs;
      root = ./.;
      extraOutputs = {
        eachSystem,
        perSystemWorkspace,
      }: {
        checks = eachSystem (system: let
          pkgs = nixpkgs.legacyPackages.${system};
          packages = perSystemWorkspace.${system}.packages;
          harness = packages.billet-acceptance;
          catalogBillets = catalog.billets.${system};
          catalogPackage = catalog.packages.${system}.catalog;
        in
          (import ./acceptance.test.nix {
            inherit pkgs billetLib harness;
            cli = packages.billet;
          })
          // (import ./oci.test.nix {inherit pkgs billetLib harness;})
          // (import ./service-validation.test.nix {inherit pkgs billetLib;})
          // (import ./bundle-validation.test.nix {inherit pkgs billetLib;})
          // (import ./public-format.test.nix {inherit pkgs;})
          // (import ./ci-app.test.nix {
            inherit pkgs;
            app = self.apps.${system}.ci;
          })
          // (import ./public-flake.test.nix {
            inherit pkgs;
            qualificationChecks = self.checks.${system};
            smoke = self.apps.${system}.oci-smoke;
          })
          // (import ./examples.test.nix {
            inherit pkgs catalogBillets catalogPackage;
            hello = hello.billets.${system}.hello;
            helloApp = hello.apps.${system}.default;
            catalogChecks = catalog.checks.${system};
          })
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (import ./compose.test.nix {
            inherit pkgs billetLib;
            catalogReport = catalogBillets.catalog-report.dockerCompose.bundle;
            catalogExecutable = "${catalogPackage}/bin/catalog";
          }));
        apps = eachSystem (system: let
          pkgs = nixpkgs.legacyPackages.${system};
          harness = perSystemWorkspace.${system}.packages.billet-acceptance;
          smoke = pkgs.writeShellApplication {
            name = "billet-oci-smoke";
            runtimeInputs = [pkgs.docker-client nix2container.packages.${system}.skopeo-nix2container];
            text = ''exec ${harness}/bin/billet-acceptance smoke "$@"'';
          };
          ci = import ./ci-app.nix {inherit pkgs;};
        in
          perSystemWorkspace.${system}.apps
          // {
            ci = {
              type = "app";
              program = "${ci}/bin/billet-ci";
            };
            oci-smoke = {
              type = "app";
              program = "${smoke}/bin/billet-oci-smoke";
            };
          });
      };
    };
}
