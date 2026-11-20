{
  description = "Billet artifact qualification";

  inputs = {
    billet = {
      url = "path:..";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    bloomery.url = "github:actionable-work/bloomery";
    nixpkgs.follows = "bloomery/nixpkgs";
    nix2container.follows = "billet/nix2container";
    treefmt-nix.follows = "billet/treefmt-nix";
  };

  outputs = {
    self,
    billet,
    bloomery,
    nixpkgs,
    nix2container,
    treefmt-nix,
    ...
  }: let
    billetLib = billet.lib;
    hello = (import ../examples/hello/flake.nix).outputs {inherit billet nixpkgs;};
    catalog = (import ../examples/catalog-report/flake.nix).outputs {inherit billet bloomery nixpkgs;};
    guestbook = (import ../examples/guestbook/flake.nix).outputs {inherit billet nixpkgs;};
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
          // (import ./image-name.test.nix {inherit pkgs billetLib harness;})
          // (import ./service-validation.test.nix {inherit pkgs billetLib;})
          // (import ./bundle-validation.test.nix {inherit pkgs billetLib;})
          // (import ./systems.test.nix {
            inherit pkgs billetLib harness;
            microvmSource = billet.inputs.microvm.outPath;
          })
          // (import ./public-format.test.nix {
            inherit pkgs treefmt-nix;
            formatting = billet.checks.${system}.formatting;
          })
          // (import ./ci-app.test.nix {
            inherit pkgs;
            app = self.apps.${system}.ci;
          })
          // (import ./public-flake.test.nix {
            inherit pkgs;
            qualificationChecks = self.checks.${system};
            smoke = self.apps.${system}.oci-smoke;
            publicFormatter = billet.formatter;
          })
          // (import ./examples.test.nix {
            inherit pkgs catalogBillets catalogPackage;
            hello = hello.billets.${system}.hello;
            helloApp = hello.apps.${system}.default;
            catalogChecks = catalog.checks.${system};
          })
          // (import ./guestbook.test.nix {
            inherit pkgs billetLib harness;
            guestbook = guestbook.billets.${system};
            guestbookChecks = guestbook.checks.${system};
          })
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (import ./kubernetes.test.nix {
            inherit pkgs billetLib;
          })
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (import ./kubernetes-bundle.test.nix {
            inherit pkgs billetLib catalogBillets;
          })
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (import ./kubernetes-vm.test.nix {
            inherit pkgs billetLib;
          })
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (import ./microvm.test.nix {
            inherit pkgs billetLib;
          })
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (import ./microvm-boot.test.nix {
            inherit pkgs billetLib;
          })
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (import ./microvm-bundle.test.nix {
            inherit pkgs billetLib catalogBillets;
          })
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (import ./compose.test.nix {
            inherit pkgs billetLib;
            catalogReport = catalogBillets.catalog-report.dockerCompose.bundle;
            catalogExecutable = "${catalogPackage}/bin/catalog";
          })
          // (import ./docs.test.nix {
            inherit pkgs billet bloomery nixpkgs;
            doctest = packages.billet-doctest;
            hello = hello;
            catalog = catalog;
            guestbook = guestbook;
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
