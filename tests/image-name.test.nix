{
  pkgs,
  billetLib,
  harness,
}: let
  inherit (pkgs) lib;
  fixtures = import ./fixtures.nix {inherit pkgs billetLib;};
  configure = options: fixtures.evaluate (lib.recursiveUpdate fixtures.base options);
  imageName = options: (configure options).ir.oci.imageName;
  rejects = name: !(builtins.tryEval (builtins.deepSeq (configure {oci.imageName = name;}).ir true)).success;
  registryName = "registry.example.com:5000/team/hello";
  registry = configure {oci.imageName = registryName;};
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
  "billet:image-name-default" = assert imageName {identity.name = "hello";} == "hello";
  assert imageName {identity.name = "Hello_World";} == "hello_world";
    marker "billet-image-name-default" {passthru.bloomery = ["BILLET-IR-NORMALIZATION-007"];};

  "billet:image-name-explicit" = assert registry.ir.oci.imageName == registryName;
  assert imageName {oci.imageName = "localhost/hello";} == "localhost/hello";
  assert imageName {oci.imageName = "team/my__app-1";} == "team/my__app-1";
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
    diagnose "billet-image-name-invalid" "imageName" "oci.imageName" {passthru.bloomery = ["BILLET-IR-VALIDATION-026"];};

  "billet:image-name-default-invalid" =
    diagnose "billet-image-name-default-invalid" "imageNameDefault" "oci.imageName" {passthru.bloomery = ["BILLET-IR-VALIDATION-027"];};

  # Image references are evaluated without building the image.
  "billet:image-name-reference" = assert !supported || lib.hasPrefix "${registryName}:" registry.ociImage.imageRefUnsafe;
  assert !supported || lib.hasPrefix "hello:" (configure {}).ociImage.imageRefUnsafe;
    marker "billet-image-name-reference" {passthru.bloomery = ["BILLET-CLOSURE-OCI-014"];};

  "billet:image-name-compose" = assert !supported || registry.dockerCompose.configuration.services.hello.image == registry.ociImage.imageRefUnsafe;
  assert !supported || lib.hasPrefix "${registryName}:" registry.dockerCompose.configuration.services.hello.image;
    marker "billet-image-name-compose" {passthru.bloomery = ["BILLET-IR-TARGETS-025"];};
}
