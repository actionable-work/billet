{
  description = "Billet: Nix application IR and deployment artifacts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    nixpkgs,
    nix2container,
    ...
  }: {
    lib = import ./lib {
      lib = nixpkgs.lib;
      inherit nix2container;
    };
  };
}
