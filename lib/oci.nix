{
  pkgs,
  billet,
  eligibility,
  nix2container,
}:
if !eligibility.supported
then throw ("billet: unsupported OCI image: " + pkgs.lib.concatMapStringsSep "; " (d: "${d.field}: ${d.reason}") eligibility.diagnostics)
else if nix2container == null
then throw "billet: OCI packaging requires the pinned nix2container flake input"
else let
  inherit (pkgs) lib;
  backend = nix2container.packages.${billet.ir.system}.nix2container;
  backendRevision = nix2container.rev;
  metadata =
    pkgs.runCommand "billet-image-root" {
      descriptor = billet.closureDescriptor;
      workingDirectory = billet.ir.process.workingDirectory;
    } ''
      mkdir -p "$out/etc/billet"
      case "$workingDirectory" in
        /nix/store|/nix/store/*)
          test -d "$workingDirectory" || {
            echo 'billet: process.workingDirectory: missing from runtime closure' >&2; exit 1;
          } ;;
        /etc/billet/manifest.json|/etc/billet/manifest.json/*|/etc/billet/closure.json|/etc/billet/closure.json/*)
          echo 'billet: process.workingDirectory: collides with image metadata' >&2; exit 1 ;;
        *) mkdir -p "$out$workingDirectory" ;;
      esac
      cp "$descriptor/manifest.json" "$out/etc/billet/manifest.json"
      cp "$descriptor/descriptor.json" "$out/etc/billet/closure.json"
    '';
  runtimeLayer = backend.buildLayer {
    deps = billet.runtimeRoots;
    metadata = {created_by = "billet-runtime-v1";};
  };
  image = backend.buildImage {
    name = billet.ir.identity.imageName;
    tag = builtins.hashString "sha256" "${billet.manifestDigest}:1:${backendRevision}";
    arch = eligibility.architecture;
    created = "1970-01-01T00:00:00Z";
    layers = [runtimeLayer];
    copyToRoot = metadata;
    config = {
      Entrypoint = [billet.ir.process.executable];
      Cmd = billet.ir.process.argv;
      Env = lib.mapAttrsToList (name: value: "${name}=${value}") billet.ir.process.environment;
      User = billet.ir.process.user;
      WorkingDir = billet.ir.process.workingDirectory;
      StopSignal = billet.ir.shutdown.stopSignal;
      Labels = {
        "org.actionable-work.billet.manifest-digest" = billet.manifestDigest;
        "org.actionable-work.billet.schema-version" = "1";
        "org.actionable-work.billet.system" = billet.ir.system;
        "org.actionable-work.billet.oci-adapter-version" = "1";
        "org.actionable-work.billet.nix2container-revision" = backendRevision;
      };
    };
  };
  reference = image.imageRefUnsafe;
  archive =
    pkgs.runCommand "billet-${billet.ir.identity.name}-docker-image.tar" {
      imageReference = reference;
    } ''
      ${lib.getExe image.copyTo} --tmpdir="$TMPDIR" --format v2s2 "docker-archive:$out:$imageReference"
    '';
  layout =
    pkgs.runCommand "billet-${billet.ir.identity.name}-oci-layout-v1" {
      nativeBuildInputs = [pkgs.jq pkgs.coreutils];
      descriptor = billet.closureDescriptor;
      manifestDigest = billet.manifestDigest;
      systemName = billet.ir.system;
      inherit backendRevision;
    } ''
      ${lib.getExe image.copyTo} --format oci "oci:$out:billet"
      imageDigest=$(jq -r '.manifests[0].digest' "$out/index.json")
      printf '%s\n' "$imageDigest" > "$out/image-digest"
      closureDigest="sha256:$(sha256sum "$descriptor/descriptor.json" | cut -d ' ' -f1)"
      jq -ncS --arg system "$systemName" --arg billet "$manifestDigest" \
        --arg image "$imageDigest" --arg descriptor "$closureDigest" --arg backend "$backendRevision" \
        '{schemaVersion: 1, adapter: "billet-oci", adapterVersion: 1, system: $system,
          backend: "nix2container", backendRevision: $backend, billetManifestDigest: $billet,
          imageManifestDigest: $image, closureDescriptorDigest: $descriptor}' > "$out/provenance.json"
    '';
in {inherit image layout reference archive;}
