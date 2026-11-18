{
  description = "Hello from Billet using a nixpkgs package";

  inputs = {
    billet.url = "path:../..";
    nixpkgs.follows = "billet/nixpkgs";
  };

  outputs = {
    billet,
    nixpkgs,
    ...
  }: let
    eachSystem = nixpkgs.lib.genAttrs ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
    billets = eachSystem (system: {
      hello = billet.lib.mkBillet {
        pkgs = nixpkgs.legacyPackages.${system};
        modules = [./application.nix];
      };
    });
  in {
    inherit billets;
    checks = eachSystem (system: {
      "billet:hello:validate" = billets.${system}.hello.validationCheck;
    });
    apps = eachSystem (system: {
      default = {
        type = "app";
        program = billets.${system}.hello.ir.process.executable;
      };
    });
  };
}
