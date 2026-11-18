{
  pkgs,
  billetLib,
}: let
  fixtures = import ./fixtures.nix {inherit pkgs billetLib;};
  inherit (fixtures.validation) service invalid;
  bundle = billets: billetLib.mkBilletBundle {inherit pkgs billets;};
  fails = value: !(builtins.tryEval value.validationCheck.drvPath).success;
  foreignSystem =
    if pkgs.stdenv.hostPlatform.system == "aarch64-linux"
    then "x86_64-linux"
    else "aarch64-linux";
  foreign = billetLib.mkBillet {
    pkgs = import pkgs.path {system = foreignSystem;};
    modules = [../examples/hello/application.nix];
  };
  grouped = bundle {trap = service;};
in {
  "billet:validate-bundle" = assert fails (bundle {});
  assert fails (bundle {incorrect = service;});
  assert fails (bundle {hello = foreign;});
  assert fails (bundle {inherit invalid;});
  assert !grouped.dockerCompose.capabilityReport.canRender;
    pkgs.runCommand "billet-validate-bundle" {
      passthru.bloomery = ["BILLET-PUBLIC-CHECKS-003" "BILLET-PUBLIC-CHECKS-004" "BILLET-PUBLIC-CHECKS-005" "BILLET-PUBLIC-CHECKS-006" "BILLET-PUBLIC-CHECKS-007"];
      validation = grouped.validationCheck;
      expected = builtins.unsafeDiscardStringContext (builtins.toJSON {trap = service.manifestDigest;});
    } ''
      test "$(cat "$validation")" = "$expected"
      touch "$out"
    '';
}
