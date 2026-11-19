{
  pkgs,
  billetLib,
  harness,
}: let
  inherit (pkgs) lib;
  fixtures = import ./fixtures.nix {inherit pkgs billetLib;};
  named = identity: fixtures.evaluate (lib.recursiveUpdate fixtures.base {inherit identity;});
  imageName = identity: (named identity).ir.identity.imageName;
  rejects = name: !(builtins.tryEval (builtins.deepSeq (named {imageName = name;}).ir true)).success;
  registryName = "registry.example.com:5000/team/hello";
  registry = named {imageName = registryName;};
  supported = pkgs.stdenv.hostPlatform.isLinux;
  marker = name: attrs: pkgs.runCommand name attrs ''touch "$out"'';
  diagnose = name: fixture: field: attrs:
    pkgs.runCommand name (attrs
      // {
        nativeBuildInputs = [pkgs.nix];
        source = ../.;
        nixpkgsSource = pkgs.path;
        system = pkgs.stdenv.hostPlatform.system;
      }) ''
      ${harness}/bin/billet-acceptance diagnose ${fixture} ${field}
      touch "$out"
    '';
in {
  "billet:image-name-default" = assert imageName {name = "hello";} == "hello";
  assert imageName {name = "Hello_World";} == "hello_world";
    marker "billet-image-name-default" {passthru.bloomery = ["BILLET-IR-NORMALIZATION-007"];};

  "billet:image-name-explicit" = assert registry.ir.identity.imageName == registryName;
  assert imageName {imageName = "localhost/hello";} == "localhost/hello";
  assert imageName {imageName = "team/my__app-1";} == "team/my__app-1";
    marker "billet-image-name-explicit" {passthru.bloomery = ["BILLET-IR-NORMALIZATION-008"];};

  "billet:image-name-invalid" = assert lib.all rejects [
    "Hello"
    "hello/"
    "/hello"
    "team//hello"
    "hello:latest"
    "hello-"
    ""
    (lib.concatStrings (lib.replicate 256 "a"))
  ];
    diagnose "billet-image-name-invalid" "imageName" "identity.imageName" {passthru.bloomery = ["BILLET-IR-VALIDATION-026"];};

  "billet:image-name-default-invalid" =
    diagnose "billet-image-name-default-invalid" "imageNameDefault" "identity.imageName" {passthru.bloomery = ["BILLET-IR-VALIDATION-027"];};

  # Image references are evaluated without building the image.
  "billet:image-name-reference" = assert !supported || lib.hasPrefix "${registryName}:" registry.ociImage.imageRefUnsafe;
  assert !supported || lib.hasPrefix "hello:" (named {name = "hello";}).ociImage.imageRefUnsafe;
    marker "billet-image-name-reference" {passthru.bloomery = ["BILLET-CLOSURE-OCI-014"];};

  "billet:image-name-compose" = assert !supported || registry.dockerCompose.configuration.services.hello.image == registry.ociImage.imageRefUnsafe;
  assert !supported || lib.hasPrefix "${registryName}:" registry.dockerCompose.configuration.services.hello.image;
    marker "billet-image-name-compose" {passthru.bloomery = ["BILLET-IR-TARGETS-025"];};
}
