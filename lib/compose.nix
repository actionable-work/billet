{
  pkgs,
  billet,
  oci,
  imageEligibility,
}: let
  inherit (pkgs) lib;
  inherit (billet) ir manifestDigest;
  name = billet.ir.identity.name;
  mapping = import ./compose-service.nix {inherit lib;} ir;
  project = import ./compose-project.nix {inherit lib;} {${name} = ir;};
  capabilityReport = (import ./targets.nix {inherit lib;}).compose {
    inherit ir manifestDigest mapping;
    image = imageEligibility;
  };
  configuration =
    if capabilityReport.canRender
    then
      project.configure {
        ${name} =
          mapping.service
          // {
            image = oci.reference;
            pull_policy = "never";
          };
      }
      // lib.optionalAttrs (mapping.secrets != {}) {inherit (mapping) secrets;}
      // lib.optionalAttrs (mapping.volumes != {}) {inherit (mapping) volumes;}
      // {
        x-billet = {
          manifest = "./manifest.json";
          manifestDigest = builtins.unsafeDiscardStringContext manifestDigest;
        };
      }
    else throw ("billet: UnsupportedTarget dockerCompose: " + lib.concatMapStringsSep "; " (d: "${d.field}: ${d.reason}") imageEligibility.diagnostics);
  file = pkgs.writeText "compose.yaml" (builtins.toJSON configuration + "\n");
  bundle = pkgs.runCommand "billet-${name}-docker-compose-v1" {} ''
    mkdir -p "$out"
    cp ${file} "$out/compose.yaml"
    cp ${oci.archive} "$out/image.tar"
    cp ${billet.manifest} "$out/manifest.json"
  '';
in {inherit capabilityReport configuration file bundle;}
