{
  lib,
  system,
}: config: let
  c = config;
  require = path: ok: reason:
    if ok
    then true
    else throw "billet: ${path}: ${reason}";
  nonempty = path: value: require path (value != "") "must be nonempty";
  positive = path: value: require path (value > 0) "must be positive";
  nonnegative = path: value: require path (value >= 0) "must be nonnegative";
  named = value: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_.-]*" value != null;
  envName = value: builtins.match "[a-zA-Z_][a-zA-Z0-9_]*" value != null;
  cleanParts = value: builtins.all (x: x != ".." && x != "." && x != "") (lib.splitString "/" value);
  absolute = value: value == "/" || (lib.hasPrefix "/" value && cleanParts (lib.removePrefix "/" value));
  overlap = a: b: a == b || lib.hasPrefix "${a}/" b || lib.hasPrefix "${b}/" a;
  unique = path: xs: require path (builtins.length xs == builtins.length (lib.unique xs)) "must be unique";
  allMap = f: attrs: lib.mapAttrsToList f attrs;
  # Subtract from a checked budget; summing untrusted integers can overflow.
  within = limit: values:
    (lib.foldl' (state: value: {
        valid = state.valid && value >= 0 && value <= state.remaining;
        remaining =
          if value >= 0 && value <= state.remaining
          then state.remaining - value
          else 0;
      }) {
        valid = limit >= 0;
        remaining = limit;
      }
      values).valid;
  command = path: p: [
    (require "${path}.package" (p.package != null) "package is required")
    (require "${path}.package" (p.package == null || (p.package.system or null) == system) "package system must match selected system")
    (require "${path}.executable" (p.executable != "" && !lib.hasPrefix "/" p.executable && cleanParts p.executable) "must be a normalized package-relative executable")
  ];
  probes = allMap (name: p:
    if p == null
    then []
    else [
      (positive "probes.${name}.intervalSeconds" p.intervalSeconds)
      (positive "probes.${name}.timeoutSeconds" p.timeoutSeconds)
      (positive "probes.${name}.failureThreshold" p.failureThreshold)
      (require "probes.${name}.timeoutSeconds" (p.timeoutSeconds <= p.intervalSeconds) "must not exceed interval")
      (require "probes.${name}.command" ((p.type == "exec") == (p.command != null)) "exec probes require a command; other probes forbid it")
      (
        if p.command != null
        then command "probes.${name}.command" p.command
        else []
      )
      (require "probes.${name}.port" (
        if p.type == "exec"
        then p.port == null
        else p.port != null && builtins.hasAttr p.port c.network.ports
      ) "must reference a declared port for network probes")
      (require "probes.${name}.port" (p.port == null || !builtins.hasAttr p.port c.network.ports || p.type == "tcp" || c.network.ports.${p.port}.protocol == p.type) "probe protocol must match port intent")
      (require "probes.${name}.path" (lib.hasPrefix "/" p.path) "must start with a slash")
    ])
  c.probes;
  mounts = map (s: s.mountPoint) (builtins.attrValues c.storage);
  fileSecrets = builtins.filter (s: s.mode == "file") (builtins.attrValues c.secrets);
  memoryScratch = map (s: s.sizeBytes) (builtins.filter (s: s.medium == "memory") (builtins.attrValues c.storage));
in
  builtins.deepSeq [
    (require "schemaVersion" (c.schemaVersion == 1) "unsupported schema version; explicit migration required")
    (require "identity.name" (named c.identity.name) "must be an identifier")
    (nonempty "identity.version" c.identity.version)
    (require "systems" (builtins.elem system c.systems) "selected system is not declared")
    (map (s: nonempty "systems" s) c.systems)
    (command "process" c.process)
    (require "process.workingDirectory" (absolute c.process.workingDirectory) "must be a normalized absolute path")
    (nonempty "process.user" c.process.user)
    (allMap (k: _: require "process.environment" (envName k) "invalid environment variable name") c.process.environment)
    (map (key: positive "resources.${key}" c.resources.${key}) ["cpuRequest" "cpuLimit" "memoryRequest" "memoryLimit"])
    (require "resources.cpuRequest" (c.resources.cpuRequest <= c.resources.cpuLimit) "exceeds limit")
    (require "resources.memoryRequest" (c.resources.memoryRequest <= c.resources.memoryLimit) "exceeds limit")
    (nonnegative "resources.replicas.min" c.resources.replicas.min)
    (require "resources.replicas.max" (c.resources.replicas.max >= c.resources.replicas.min) "must be at least min")
    (
      if c.resources.targetMetric == null
      then true
      else nonempty "resources.targetMetric" c.resources.targetMetric
    )
    (map (nonempty "resources.placement") c.resources.placement)
    (require "resources.strictSingleton" (!c.resources.strictSingleton || (c.resources.replicas.max <= 1 && c.rollout.maxSurge == 0)) "singleton forbids concurrent replicas and positive surge")
    (positive "initialization.startupAllowanceSeconds" c.initialization.startupAllowanceSeconds)
    (nonnegative "initialization.budgetSeconds" c.initialization.budgetSeconds)
    (require "initialization.budgetSeconds" (c.initialization.budgetSeconds <= c.initialization.startupAllowanceSeconds && within c.initialization.budgetSeconds (map (s: s.timeoutSeconds) c.initialization.steps)) "must contain all step timeouts within startup allowance")
    (unique "initialization.steps.id" (map (s: s.id) c.initialization.steps))
    (lib.imap0 (i: s: [
        (require "initialization.steps.${toString i}.id" (named s.id) "must be an identifier")
        (positive "initialization.steps.${toString i}.timeoutSeconds" s.timeoutSeconds)
        (command "initialization.steps.${toString i}" s)
      ])
      c.initialization.steps)
    probes
    (nonnegative "restart.maxRetries" c.restart.maxRetries)
    (map (key: positive "restart.${key}" c.restart.${key}) ["initialDelaySeconds" "maxDelaySeconds" "continuousReadyResetSeconds"])
    (require "restart.maxDelaySeconds" (c.restart.maxDelaySeconds >= c.restart.initialDelaySeconds) "must be at least initial delay")
    (require "restart.multiplier" (c.restart.multiplier > 1) "must exceed one")
    (require "restart.triggers" (!c.restart.enabled || c.restart.triggers != []) "enabled restart requires failure triggers")
    (nonnegative "shutdown.stopGracePeriodSeconds" c.shutdown.stopGracePeriodSeconds)
    (map (key: nonnegative "rollout.${key}" c.rollout.${key}) ["maxSurge" "maxUnavailable" "minReadySeconds"])
    (positive "rollout.progressDeadlineSeconds" c.rollout.progressDeadlineSeconds)
    (require "rollout.maxSurge" (c.rollout.maxSurge > 0 || c.rollout.maxUnavailable > 0) "rollout requires a progress allowance")
    (require "rollout.maxUnavailable" (c.resources.replicas.min == 0 || c.rollout.maxUnavailable <= c.resources.replicas.min) "exceeds minimum desired replicas")
    (allMap (name: p: [
        (require "network.ports" (named name) "invalid port name")
        (require "network.ports.${name}.port" (p.port >= 1 && p.port <= 65535) "must be in 1..65535")
      ])
      c.network.ports)
    (unique "network.ports.port" (map (p: p.port) (builtins.attrValues c.network.ports)))
    (map (p: map (key: require "network.privateConnections.${key}" (named p.${key}) "must be an identifier") ["sourceService" "destinationService" "destinationPort"]) c.network.privateConnections)
    (map (nonempty "network.egressRestrictions") c.network.egressRestrictions)
    (allMap (name: s: [
        (require "secrets" (named name) "invalid logical name")
        (nonempty "secrets.${name}.external" s.external)
        (require "secrets.${name}" (!builtins.hasContext s.external && !builtins.hasContext s.target) "references cannot carry store dependencies")
        (require "secrets.${name}.target" (
          if s.mode == "file"
          then absolute s.target && s.target != "/"
          else envName s.target
        ) "invalid injection target")
        (require "secrets.${name}.target" (s.mode != "environment" || !builtins.hasAttr s.target c.process.environment) "collides with non-secret environment")
      ])
      c.secrets)
    (unique "secrets.target" (map (s: "${s.mode}:${s.target}") (builtins.attrValues c.secrets)))
    (map (s: require "secrets.target" (!(builtins.any (m: overlap m s.target) mounts)) "file delivery overlaps a storage mount") fileSecrets)
    (require "secrets.target" (builtins.all (a: builtins.all (b: a.target == b.target || !overlap a.target b.target) fileSecrets) fileSecrets) "file delivery paths overlap")
    (allMap (name: s: [
        (require "storage" (named name) "invalid claim name")
        (require "storage.${name}.mountPoint" (absolute s.mountPoint && s.mountPoint != "/") "must be a normalized non-root absolute path")
        (positive "storage.${name}.sizeBytes" s.sizeBytes)
        (nonempty "storage.${name}.driverClass" s.driverClass)
        (require "storage.${name}.medium" (s.medium != "memory" || s.lifecycle == "ephemeral") "memory claims must be ephemeral")
      ])
      c.storage)
    (unique "storage.mountPoint" mounts)
    (require "storage.mountPoint" (builtins.all (a: builtins.all (b: a == b || !overlap a b) mounts) mounts) "mounts overlap")
    (require "storage.sizeBytes" (within c.resources.memoryLimit memoryScratch) "memory scratch exceeds memory limit")
    (map (nonempty "requiredCapabilities") c.requiredCapabilities)
  ]
  true
