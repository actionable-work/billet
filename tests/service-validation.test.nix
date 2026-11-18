{
  pkgs,
  billetLib,
}: let
  fixtures = import ./fixtures.nix {inherit pkgs billetLib;};
  inherit (fixtures.validation) service invalid;
in {
  "billet:validate-service" = assert !(builtins.tryEval invalid.validationCheck.drvPath).success;
    pkgs.runCommand "billet-validate-service" {
      passthru.bloomery = ["BILLET-PUBLIC-CHECKS-001" "BILLET-PUBLIC-CHECKS-002"];
      validation = service.validationCheck;
      expectedDigest = builtins.unsafeDiscardStringContext service.manifestDigest;
    } ''
      test "$(cat "$validation")" = "$expectedDigest"
      touch "$out"
    '';
}
