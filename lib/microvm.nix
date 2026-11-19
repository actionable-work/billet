{
  pkgs,
  billet,
  microvm,
  settings,
}: let
  inherit (pkgs) lib;
  inherit (billet) ir manifestDigest;
  inherit (ir) system process resources shutdown;
  mib = 1024 * 1024;
  identities = lib.splitString ":" process.user;
  validId = value:
    builtins.match "0|[1-9][0-9]{0,9}" value
    != null
    && value != "65535"
    && builtins.fromJSON value < 4294967295;
  plainPath = path:
    builtins.stringLength path
    < 4096
    && builtins.match ".*[[:cntrl:]].*" path == null
    && builtins.all (component: builtins.stringLength component <= 255) (lib.splitString "/" path);
  diagnostic = severity: code: capability: field: reason: {inherit severity code capability field reason;};
  error = code: diagnostic "error" code "microvm-packaging";
  warning = diagnostic "warning";
  errors =
    lib.optional (microvm == null)
    (error "MissingMicrovmInput" "microvm" "the MicroVM.nix guest module is required")
    ++ lib.optional (ir.schemaVersion != 1 || ir.normalizationVersion != 1)
    (error "UnsupportedSchemaVersion" "schemaVersion" "the microVM renderer requires Billet IR and normalization v1")
    ++ lib.optional (!(builtins.elem system ["x86_64-linux" "aarch64-linux"]))
    (error "UnsupportedMicrovmSystem" "systems" "the microVM profile supports x86_64-linux and aarch64-linux")
    ++ lib.optional (pkgs.stdenv.buildPlatform.system != system)
    (error "MicrovmSystemMismatch" "system" "the build and guest platforms must match")
    ++ lib.optional (builtins.length identities != 2 || !builtins.all validId identities)
    (error "UnsupportedMicrovmUser" "process.user" "the microVM service requires a valid numeric UID and GID")
    ++ lib.optional (!plainPath process.executable || builtins.any (c: lib.hasInfix c process.executable) ["\\" "\"" "'" "*" "?" "["])
    (error "UnsupportedMicrovmExecutable" "process.executable" "the executable path must be representable in a systemd service")
    ++ lib.optional (!plainPath process.workingDirectory || lib.hasSuffix "\\" process.workingDirectory || lib.hasSuffix " " process.workingDirectory)
    (error "UnsupportedMicrovmWorkingDirectory" "process.workingDirectory" "the working directory must be representable in a systemd service")
    ++ lib.optional (resources.cpuLimit > 64000)
    (error "MicrovmCPUCapacity" "resources.cpuLimit" "the microVM profile supports at most 64 vCPUs")
    ++ lib.optional (resources.memoryLimit > 1024 * 1024 * mib)
    (error "MicrovmMemoryCapacity" "resources.memoryLimit" "the microVM profile supports application memory limits up to 1 TiB")
    ++ lib.optional (shutdown.stopGracePeriodSeconds > 18446744073709)
    (error "MicrovmShutdownDuration" "shutdown.stopGracePeriodSeconds" "the stop grace period exceeds the systemd duration range");
  diagnostics =
    errors
    ++ [
      (warning "MicrovmCPURequest" "resources" "resources.cpuRequest" "CPU reservation is consumer policy")
      (warning "MicrovmMemoryRequest" "resources" "resources.memoryRequest" "memory reservation is consumer policy")
      (warning "MicrovmRollout" "rolling-rollout" "rollout" "rollout is consumer policy")
    ]
    ++ lib.optional (ir.initialization.steps != [])
    (warning "MicrovmInitialization" "initialization-every-start" "initialization.steps" "initialization steps require a consumer mapping")
    ++ lib.concatLists (lib.mapAttrsToList (phase: probe:
      lib.optional (probe != null) (warning "MicrovmProbe" "probes" "probes.${phase}" "probe scheduling requires a consumer mapping"))
    ir.probes)
    ++ lib.optional ir.restart.enabled
    (warning "MicrovmRestart" "bounded-durable-restart" "restart" "bounded durable restart is consumer policy")
    ++ lib.optional (resources.replicas.min != 1 || resources.replicas.max != 1)
    (warning "MicrovmReplicas" "scaling" "resources.replicas" "replica counts are consumer policy")
    ++ lib.optional (resources.targetMetric != null)
    (warning "MicrovmScalingMetric" "scaling" "resources.targetMetric" "scaling metrics are consumer policy")
    ++ lib.optional (resources.placement != [])
    (warning "MicrovmPlacement" "placement" "resources.placement" "placement is consumer policy")
    ++ lib.optional resources.strictSingleton
    (warning "MicrovmSingleton" "placement" "resources.strictSingleton" "strict singleton is consumer policy")
    ++ lib.optional (ir.network.ports != {})
    (warning "MicrovmPorts" "network-ports" "network.ports" "ports require a consumer network mapping")
    ++ lib.optional (ir.network.privateConnections != [])
    (warning "MicrovmPrivateConnections" "directional-private-network-policy" "network.privateConnections" "private connections are consumer policy")
    ++ lib.optional (!ir.network.publicEgress)
    (warning "MicrovmPublicEgress" "egress-policy" "network.publicEgress" "egress policy requires a consumer network mapping")
    ++ lib.optional (ir.network.egressRestrictions != [])
    (warning "MicrovmEgressRestrictions" "egress-policy" "network.egressRestrictions" "egress restrictions are consumer policy")
    ++ lib.mapAttrsToList (name: claim:
      warning "MicrovmStorage" "storage-${claim.lifecycle}-${claim.medium}" "storage.${name}" "storage claims require a consumer mapping")
    ir.storage
    ++ lib.mapAttrsToList (name: _:
      warning "MicrovmSecret" "runtime-secrets" "secrets.${name}" "secret delivery requires a consumer mapping")
    ir.secrets;
  canRender = errors == [];
  requireEligible = value:
    if canRender
    then value
    else throw ("billet: microvm: " + lib.concatMapStringsSep "; " (item: "${item.field}: ${item.reason}") errors);

  escapeSpecifiers = builtins.replaceStrings ["%"] ["%%"];
  unitWord = value: builtins.toJSON (escapeSpecifiers value);
  tcg = settings.acceleration == "tcg";
  guestMemory = builtins.div (resources.memoryLimit + mib - 1) mib + 512;
  nativeSettings = {
    system.stateVersion = "26.05";
    networking.hostName = "billet";
    # The native QEMU shutdown command delivers a virtual power-button event.
    boot.kernelModules = ["evdev"] ++ lib.optional (system == "x86_64-linux") "button";
    environment.etc."billet/manifest.json".source = "${billet.closureDescriptor}/manifest.json";
    microvm =
      {
        hypervisor = "qemu";
        vcpu = builtins.div (resources.cpuLimit + 999) 1000;
        # QEMU hangs with exactly 2 GiB of guest memory (microvm.nix#171).
        mem =
          if guestMemory == 2048
          then 2049
          else guestMemory;
        storeOnDisk = true;
        interfaces = [];
      }
      // lib.optionalAttrs tcg {
        cpu = "max";
        qemu.machineOpts =
          {accel = "tcg";}
          // (
            if system == "aarch64-linux"
            then {gic-version = "max";}
            else {acpi = "on";}
          );
      };
    systemd.services.billet = {
      description = "Billet application";
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "exec";
        # The colon disables systemd's environment substitution in the command.
        ExecStart = lib.concatStringsSep " " (map unitWord ([":${process.executable}"] ++ process.argv));
        Environment = lib.mapAttrsToList (name: value: unitWord "${name}=${value}") process.environment;
        WorkingDirectory = escapeSpecifiers process.workingDirectory;
        User = builtins.elemAt identities 0;
        Group = builtins.elemAt identities 1;
        CPUQuota = "${toString (builtins.div resources.cpuLimit 10)}.${toString (lib.mod resources.cpuLimit 10)}%";
        CPUQuotaPeriodSec = "1s";
        MemoryMax = toString resources.memoryLimit;
        KillMode = "control-group";
        KillSignal = shutdown.stopSignal;
        TimeoutStopSec =
          if shutdown.stopGracePeriodSeconds == 0
          then "1us"
          else "${toString shutdown.stopGracePeriodSeconds}s";
        Restart = "no";
        StandardOutput = "journal+console";
        StandardError = "inherit";
      };
    };
  };
  evaluateGuest = import ./microvm-guest.nix {inherit pkgs microvm;};
  baseGuest = evaluateGuest [nativeSettings];
  # systemd resolves numeric identities through the guest account database.
  # Check the base guest first so existing system IDs can be used directly.
  accounts = let
    uid = builtins.fromJSON (builtins.elemAt identities 0);
    gid = builtins.fromJSON (builtins.elemAt identities 1);
    existingUser = builtins.any (user: user.enable && user.uid == uid) (builtins.attrValues baseGuest.config.users.users);
    existingGroup = lib.findFirst (group: group.gid == gid) null (builtins.attrValues baseGuest.config.users.groups);
  in {
    groups = lib.optionalAttrs (existingGroup == null) {billet-process.gid = gid;};
    users = lib.optionalAttrs (!existingUser) {
      billet-process = {
        inherit uid;
        isSystemUser = true;
        group =
          if existingGroup == null
          then "billet-process"
          else existingGroup.name;
      };
    };
  };
  configuration = requireEligible (nativeSettings // {users = accounts;});
  guest = baseGuest.extendModules {modules = [{users = accounts;}];};
  runner = requireEligible guest.config.microvm.declaredRunner;
  file = requireEligible (pkgs.writeText "microvm.json" (builtins.unsafeDiscardStringContext (builtins.toJSON configuration)));
in {
  inherit configuration file runner;
  capabilityReport = {
    schemaVersion = 1;
    target = "microvm";
    profile = "microvm-artifact-v1";
    profileVersion = 1;
    rendererVersion = 1;
    mode = "artifact-only";
    inherit system manifestDigest canRender diagnostics;
    inherit (ir) requiredCapabilities;
    supportedCapabilities = lib.optionals canRender ["process-tree-cleanup" "resource-limits" "shutdown"];
  };
  bundle = requireEligible (pkgs.runCommand "billet-microvm-v1" {} ''
    mkdir -p "$out"
    ln -s ${runner} "$out/runner"
    cp ${file} "$out/microvm.json"
    cp ${billet.closureDescriptor}/manifest.json "$out/manifest.json"
  '');
}
