{lib}: ir: let
  inherit (lib) filterAttrs mapAttrsToList optional optionalAttrs;
  inherit (builtins) attrValues;
  warning = code: field: capability: reason: {
    inherit code field capability reason;
    severity = "warning";
  };
  literal = value: lib.replaceStrings ["$"] ["$$"] (builtins.unsafeDiscardStringContext value);
  seconds = value: "${toString value}s";
  cores = millicores: let
    whole = builtins.div millicores 1000;
    fraction = lib.mod millicores 1000;
  in "${toString whole}.${lib.fixedWidthString 3 "0" (toString fraction)}";
  inherit (ir) resources shutdown restart probes network initialization;
  retries = restart.enabled && restart.maxRetries > 0 && builtins.elem "unexpected-exit" restart.triggers;
  healthProbeName = lib.findFirst (name: probes.${name} != null && probes.${name}.type == "exec") null ["readiness" "liveness"];
  healthProbe =
    if healthProbeName == null
    then null
    else probes.${healthProbeName};
  # Compose durations are signed 64-bit nanoseconds. Bound the startup
  # multiplication before encoding seconds so the two IR integers cannot overflow.
  maxSeconds = 9223372036;
  nativeDurations =
    [
      {
        field = "shutdown.stopGracePeriodSeconds";
        value = shutdown.stopGracePeriodSeconds;
        capability = "shutdown";
      }
    ]
    ++ lib.optionals (healthProbe != null) (map (name: {
      field = "probes.${healthProbeName}.${name}";
      value = healthProbe.${name};
      capability = "probes";
    }) ["intervalSeconds" "timeoutSeconds"]);
  durationErrors = map (duration: {
    code = "UnsupportedComposeDuration";
    severity = "error";
    inherit (duration) field capability;
    reason = "exceeds the native Compose duration range";
  }) (builtins.filter (duration: duration.value > maxSeconds) nativeDurations);
  startupWindowTooLarge =
    if probes.startup == null
    then initialization.startupAllowanceSeconds > maxSeconds
    else probes.startup.intervalSeconds > builtins.div maxSeconds probes.startup.failureThreshold;
  startPeriod =
    if startupWindowTooLarge
    then maxSeconds
    else if probes.startup != null
    then probes.startup.intervalSeconds * probes.startup.failureThreshold
    else initialization.startupAllowanceSeconds;
  healthcheck = {
    test = ["CMD"] ++ map literal ([healthProbe.command.executable] ++ healthProbe.command.argv);
    interval = seconds healthProbe.intervalSeconds;
    timeout = seconds healthProbe.timeoutSeconds;
    retries = healthProbe.failureThreshold;
    start_period = seconds startPeriod;
  };

  ports = filterAttrs (_: port: port.exposure == "public" && network.publicEgress) network.ports;
  exposed = filterAttrs (_: port: port.exposure == "private" || !network.publicEgress) network.ports;
  # Keep the encoding injective even when two logical names differ only in
  # punctuation, casing, or where the service/claim boundary falls.
  encode = lib.replaceStrings ["-" "." "_"] ["_H" "_D" "_U"];
  key = name: "${encode ir.identity.name}__${encode name}";
  secretVariable = name: "BILLET_SECRET_${key name}";
  fileSecrets = filterAttrs (_: secret: secret.mode == "file") ir.secrets;
  environmentSecrets = filterAttrs (_: secret: secret.mode == "environment") ir.secrets;
  user = lib.splitString ":" ir.process.user;
  memory = filterAttrs (_: claim: claim.medium == "memory") ir.storage;
  disk = filterAttrs (_: claim: claim.medium == "disk") ir.storage;
  persistent = filterAttrs (_: claim: claim.lifecycle == "persistent") disk;
  ephemeral = filterAttrs (_: claim: claim.lifecycle == "ephemeral") disk;

  service =
    {
      deploy = {
        replicas = resources.replicas.min;
        resources = {
          limits = {
            cpus = cores resources.cpuLimit;
            memory = toString resources.memoryLimit;
          };
          reservations = {
            cpus = cores resources.cpuRequest;
            memory = toString resources.memoryRequest;
          };
        };
      };
      stop_signal = shutdown.stopSignal;
      stop_grace_period = seconds shutdown.stopGracePeriodSeconds;
      restart =
        if retries
        then "on-failure:${toString restart.maxRetries}"
        else "no";
    }
    // optionalAttrs (healthProbe != null) {inherit healthcheck;}
    // optionalAttrs (ports != {}) {
      ports = map (port: {
        target = port.port;
        protocol = "tcp";
      }) (attrValues ports);
    }
    // optionalAttrs (exposed != {}) {expose = map (port: toString port.port) (attrValues exposed);}
    // optionalAttrs (fileSecrets != {}) {
      secrets =
        mapAttrsToList (name: secret: {
          source = key name;
          target = literal secret.target;
          uid = builtins.head user;
          gid = builtins.elemAt user 1;
          mode = 256; # 0400
        })
        fileSecrets;
    }
    // optionalAttrs (environmentSecrets != {}) {
      environment = builtins.listToAttrs (mapAttrsToList (name: secret: {
          name = secret.target;
          value =
            if secret.required
            then "${"$"}{${secretVariable name}:?set ${secretVariable name} for Docker Compose}"
            else "${"$"}{${secretVariable name}:-}";
        })
        environmentSecrets);
    }
    // optionalAttrs (ir.storage != {}) {
      volumes = mapAttrsToList (name: claim:
        {
          target = literal claim.mountPoint;
          read_only = claim.accessMode == "readOnlyMany";
        }
        // (
          if claim.medium == "memory"
          then {
            type = "tmpfs";
            tmpfs.size = claim.sizeBytes;
          }
          else {type = "volume";} // optionalAttrs (claim.lifecycle == "persistent") {source = key name;}
        ))
      ir.storage;
    };
  diagnostics =
    durationErrors
    ++ import ./container-mount-diagnostics.nix {inherit lib;} ir
    # Compose parses cores and multiplies by 1e9 in float32 before the int64 cast.
    ++ optional (resources.cpuLimit > 9223371264000) {
      code = "UnsupportedComposeCpuLimit";
      field = "resources.cpuLimit";
      capability = "resources";
      severity = "error";
      reason = "exceeds the native Compose CPU limit range";
    }
    ++ [(warning "ComposeCPUReservation" "resources.cpuRequest" "resources" "standalone Docker Compose does not apply CPU reservations")]
    ++ optional (resources.replicas.min != resources.replicas.max)
    (warning "ComposeReplicaRange" "resources.replicas.max" "replicas" "Compose runs a fixed count at the declared minimum")
    ++ mapAttrsToList (name: _: warning "UnsupportedComposeNetworkProbe" "probes.${name}.type" "probes" "the Compose image profile does not supply a network probe client")
    (filterAttrs (_: probe: probe != null && probe.type != "exec") probes)
    ++ optional (healthProbe != null && startupWindowTooLarge)
    (warning "ComposeStartupWindowLimited" (
      if probes.startup == null
      then "initialization.startupAllowanceSeconds"
      else "probes.startup"
    ) "probes" "startup window exceeds the Compose duration range and was capped")
    ++ optional (initialization.steps != [])
    (warning "UnsupportedComposeInitialization" "initialization.steps" "initialization-every-start" "Compose cannot run these steps in the application container on every start")
    ++ mapAttrsToList (name: _: warning "ComposeInternalPort" "network.ports.${name}.exposure" "network-ports" "Docker does not publish ports for a container attached only to an internal network")
    (filterAttrs (_: port: port.exposure == "public" && !network.publicEgress) network.ports)
    ++ import ./consumer-bandwidth-diagnostics.nix {inherit lib;} network "ComposeBandwidth"
    ++ mapAttrsToList (name: _: warning "ComposeOptionalFileSecret" "secrets.${name}.required" "runtime-secrets" "Compose requires the host variable to be set for a file source; use an empty value to omit delivery")
    (filterAttrs (_: secret: !secret.required) fileSecrets)
    ++ mapAttrsToList (name: _: warning "ComposeDiskQuota" "storage.${name}.sizeBytes" "storage" "Compose local volumes do not have a size limit")
    disk;
  supportedCapabilities = lib.sort builtins.lessThan (
    ["resources" "replicas" "shutdown" "restart"]
    ++ optional (healthProbe != null) "probes"
    ++ optional (ir.secrets != {}) "runtime-secrets"
    ++ optional (network.ports != {}) "network-ports"
    ++ optional (!network.publicEgress) "network-egress-isolation"
    ++ optional (memory != {}) "storage-ephemeral-memory"
    ++ optional (ephemeral != {}) "storage-ephemeral-disk"
    ++ optional (persistent != {}) "storage-persistent-disk"
  );
in {
  inherit service diagnostics supportedCapabilities;
  secrets = lib.mapAttrs' (name: _: lib.nameValuePair (key name) {environment = secretVariable name;}) fileSecrets;
  volumes = lib.mapAttrs' (name: _: lib.nameValuePair (key name) {}) persistent;
}
