{
  description = "Billet artifact qualification";

  inputs = {
    billet.url = "path:..";
    nixpkgs.follows = "billet/nixpkgs";
    nix2container.follows = "billet/nix2container";
  };

  outputs = {
    billet,
    nixpkgs,
    nix2container,
    ...
  }: let
    inherit (nixpkgs) lib;
    billetLib = billet.lib;
    eachSystem = lib.genAttrs (builtins.attrNames billet.packages);
  in {
    checks = eachSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      packages = billet.packages.${system};
      harness = packages.billet-acceptance;
    in
      (import ./acceptance.test.nix {
        inherit pkgs billetLib harness;
        cli = packages.billet;
      })
      // (import ./oci.test.nix {inherit pkgs billetLib harness;})
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (import ./compose.test.nix {inherit pkgs billetLib;}));
    apps = eachSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      smoke = pkgs.writeShellApplication {
        name = "billet-oci-smoke";
        runtimeInputs = [pkgs.docker-client nix2container.packages.${system}.skopeo-nix2container];
        text = ''exec ${billet.packages.${system}.billet-acceptance}/bin/billet-acceptance smoke "$@"'';
      };
    in {
      oci-smoke = {
        type = "app";
        program = "${smoke}/bin/billet-oci-smoke";
      };
    });
  };
}
