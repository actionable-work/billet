{
  pkgs,
  billet,
  oci,
  capabilityReport,
}: let
  name = billet.ir.identity.name;
  configuration =
    if capabilityReport.canRender
    then {
      services.${name} = {
        image = oci.reference;
        pull_policy = "never";
      };
      x-billet = {
        manifest = "./manifest.json";
        manifestDigest = builtins.unsafeDiscardStringContext billet.manifestDigest;
      };
    }
    else throw ("billet: UnsupportedTarget dockerCompose: " + pkgs.lib.concatMapStringsSep "; " (d: "${d.field}: ${d.reason}") capabilityReport.diagnostics);
  file = pkgs.writeText "compose.yaml" (builtins.toJSON configuration + "\n");
  bundle = pkgs.runCommand "billet-${name}-docker-compose-v1" {} ''
    mkdir -p "$out"
    cp ${file} "$out/compose.yaml"
    cp ${oci.archive} "$out/image.tar"
    cp ${billet.manifest} "$out/manifest.json"
  '';
in {inherit capabilityReport configuration file bundle;}
