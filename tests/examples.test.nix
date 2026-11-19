{
  pkgs,
  hello,
  helloApp,
  catalogBillets,
  catalogPackage,
  catalogChecks,
}: let
  inherit (pkgs) lib;
  catalog = catalogBillets.catalog;
  names = ["catalog" "catalog-report" "report"];
in {
  "billet:example-outputs" = assert helloApp.program == hello.ir.process.executable;
  assert catalog.ir.process.package == toString catalogPackage;
  assert catalog.ir.oci.imageName == "billet-example/catalog";
    pkgs.runCommand "billet-example-outputs" {
      passthru.bloomery = ["BILLET-IR-TARGETS-022" "BILLET-IR-TARGETS-023"];
    } ''
      test -x ${helloApp.program}
      test -x ${catalogPackage}/bin/catalog
      touch "$out"
    '';

  "billet:catalog-validation" = assert builtins.attrNames catalogBillets == names;
  assert lib.all (name: catalogChecks."billet:${name}:validate".drvPath == catalogBillets.${name}.validationCheck.drvPath) names;
    pkgs.runCommand "billet-catalog-validation" {
      passthru.bloomery = ["BILLET-PUBLIC-BUILD-006"];
      checks = map (name: catalogChecks."billet:${name}:validate") names;
    } ''
      for check in $checks; do
        test -s "$check"
      done
      touch "$out"
    '';
}
