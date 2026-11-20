{
  description = "A Python guestbook and its PostgreSQL database with dev and prod overlays";

  inputs = {
    billet.url = "path:../..";
    nixpkgs.follows = "billet/nixpkgs";
  };

  outputs = {
    billet,
    nixpkgs,
    ...
  }: let
    eachSystem = nixpkgs.lib.genAttrs ["x86_64-linux" "aarch64-linux"];
    billets = eachSystem (system:
      import ./billets.nix {
        billetLib = billet.lib;
        pkgs = nixpkgs.legacyPackages.${system};
      });
  in {
    inherit billets;
    checks = eachSystem (system:
      nixpkgs.lib.concatMapAttrs (environment: bundle:
        {"billet:${environment}:validate" = bundle.validationCheck;}
        // nixpkgs.lib.mapAttrs' (name: member: nixpkgs.lib.nameValuePair "billet:${environment}:${name}:validate" member.validationCheck) bundle.billets)
      billets.${system});
  };
}
