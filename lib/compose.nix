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
  renderable = capabilityReport.canRender || throw ("billet: UnsupportedTarget dockerCompose: " + lib.concatMapStringsSep "; " (d: "${d.field}: ${d.reason}") (builtins.filter (d: (d.severity or "error") == "error") capabilityReport.diagnostics));
  configuration = assert renderable;
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
    };
  file = assert renderable; pkgs.writeText "compose.yaml" (builtins.toJSON configuration + "\n");
  bundle = assert renderable;
    pkgs.runCommand "billet-${name}-docker-compose-v1" {} ''
      mkdir -p "$out"
      cp ${file} "$out/compose.yaml"
      cp ${oci.archive} "$out/image.tar"
      cp ${billet.manifest} "$out/manifest.json"
    '';
in {inherit capabilityReport configuration file bundle;}
