{
  lib,
  nix2container ? null,
}: {
  mkBilletBundle = import ./compose-bundle.nix {inherit lib;};

  mkBillet = {
    pkgs,
    modules,
  }: let
    system = pkgs.stdenv.hostPlatform.system;
    schema = import ./schema.nix {inherit lib system;};
    evaluated = lib.evalModules {
      modules = [schema.module] ++ modules;
      specialArgs = {inherit pkgs;};
    };
    raw = evaluated.config;
    # The image repository defaults to the application name; IR records the
    # effective value.
    c =
      raw
      // {
        identity =
          raw.identity
          // {
            imageName =
              if raw.identity.imageName == null
              then lib.toLower raw.identity.name
              else raw.identity.imageName;
          };
      };
    checked = builtins.deepSeq (schema.checkUnknown raw) (import ./validate.nix {inherit lib system;} c);
    sorted = xs: lib.sort builtins.lessThan (lib.unique xs);
    command = p: {
      package = toString p.package;
      executable = "${p.package}/${p.executable}";
      inherit (p) argv;
    };
    probes = lib.mapAttrs (_: p:
      if p == null
      then null
      else
        p
        // {
          command =
            if p.command == null
            then null
            else command p.command;
        })
    c.probes;
    capabilities =
      ["resources" "process-tree-cleanup" "shutdown" "rolling-rollout" "readiness-hold" "rollout-deadline"]
      ++ lib.optional c.restart.enabled "bounded-durable-restart"
      ++ lib.optional c.rollout.automaticRollback "bounded-rollback-current-secrets"
      ++ lib.optional (c.initialization.steps != []) "initialization-every-start"
      ++ lib.optional (builtins.any (p: p != null) (builtins.attrValues c.probes)) "probes"
      ++ lib.optional (c.secrets != {}) "runtime-secrets"
      ++ lib.optional (c.network.ports != {}) "network-ports"
      ++ lib.optional (c.network.privateConnections != []) "directional-private-network-policy"
      ++ lib.optional (!c.network.publicEgress || c.network.egressRestrictions != []) "egress-policy"
      ++ lib.optional (c.resources.replicas.min != 1 || c.resources.replicas.max != 1 || c.resources.targetMetric != null) "scaling"
      ++ lib.optional (c.resources.placement != [] || c.resources.strictSingleton) "placement"
      ++ map (s: "storage-${s.lifecycle}-${s.medium}") (builtins.attrValues c.storage);
    ir = assert checked; {
      schemaVersion = c.schemaVersion;
      normalizationVersion = 1;
      inherit system;
      inherit (c) identity shutdown rollout secrets storage;
      systems = sorted c.systems;
      process = command c.process // {inherit (c.process) environment workingDirectory user;};
      initialization = c.initialization // {steps = map (s: command s // {inherit (s) id timeoutSeconds;}) c.initialization.steps;};
      resources = c.resources // {placement = sorted c.resources.placement;};
      inherit probes;
      restart = c.restart // {triggers = sorted c.restart.triggers;};
      network =
        c.network
        // {
          egressRestrictions = sorted c.network.egressRestrictions;
          privateConnections = lib.sort (a: b: builtins.toJSON a < builtins.toJSON b) (lib.unique c.network.privateConnections);
        };
      requiredCapabilities = sorted (c.requiredCapabilities ++ capabilities);
    };
    canonicalJSON = builtins.toJSON ir;
    manifestDigest = "sha256:${builtins.hashString "sha256" canonicalJSON}";
    manifest = pkgs.writeText "billet-${c.identity.name}-manifest.json" canonicalJSON;
    validationCheck = builtins.deepSeq ir (
      pkgs.writeText "billet-${c.identity.name}-validation" (builtins.unsafeDiscardStringContext manifestDigest + "\n")
    );
    primaryCommands =
      [
        {
          command = c.process;
          field = "process.executable";
        }
      ]
      ++ lib.imap0 (i: command: {
        inherit command;
        field = "initialization.steps.${toString i}.executable";
      })
      c.initialization.steps
      ++ lib.concatLists (lib.mapAttrsToList (name: p:
        lib.optional (p != null && p.command != null) {
          command = p.command;
          field = "probes.${name}.command.executable";
        })
      c.probes);
    # The immutable manifest retains store references in configuration strings.
    runtimeRoots = sorted (map (p: toString p.command.package) primaryCommands ++ [(toString manifest)]);
    closureDescriptor = import ./closure.nix {
      inherit pkgs system ir canonicalJSON manifestDigest runtimeRoots primaryCommands;
    };
    billet = {inherit ir canonicalJSON manifestDigest manifest runtimeRoots closureDescriptor validationCheck;};
    targets = import ./targets.nix {inherit lib;};
    imageEligibility = targets.oci {
      inherit ir manifestDigest;
      pkgsSystem = system;
    };
    oci = import ./oci.nix {
      inherit pkgs billet nix2container;
      eligibility = imageEligibility;
    };
  in
    billet
    // {
      ociImage = oci.image;
      ociLayout = oci.layout;
      dockerImage = oci.archive;
      dockerCompose = import ./compose.nix {inherit pkgs billet oci imageEligibility;};
    };
}
