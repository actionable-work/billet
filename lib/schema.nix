{
  lib,
  system,
}: let
  inherit (lib) types mkOption;
  fail = loc: reason: throw "billet: ${lib.concatStringsSep "." loc}: ${reason}";
  scalar = name: check: default: {
    kind = "scalar";
    inherit name check default;
  };
  str = scalar "string" builtins.isString "";
  int = default: scalar "integer" builtins.isInt default;
  bool = default: scalar "boolean" builtins.isBool default;
  enum = values: default: scalar "supported enum member" (v: builtins.isString v && builtins.elem v values) default;
  record = fields: {
    kind = "record";
    inherit fields;
    default = {};
    check = builtins.isAttrs;
    name = "record";
  };
  list = item: {
    kind = "list";
    inherit item;
    default = [];
    check = builtins.isList;
    name = "list";
  };
  attrs = item: {
    kind = "attrs";
    inherit item;
    default = {};
    check = builtins.isAttrs;
    name = "named map";
  };
  nullable = item: {
    kind = "nullable";
    inherit item;
    default = null;
    check = v: v == null || item.check v;
    name = "nullable ${item.name}";
  };
  package = nullable (scalar "package derivation" lib.isDerivation null);
  command = record {
    inherit package;
    executable = str;
    argv = list str;
  };
  probe = nullable (record {
    type = enum ["exec" "tcp" "http" "grpc"] "exec";
    command = nullable command;
    port = nullable str;
    path = str // {default = "/";};
    intervalSeconds = int 10;
    timeoutSeconds = int 1;
    failureThreshold = int 3;
  });
  fields = {
    schemaVersion = int 1;
    identity = record {
      name = str;
      version = str;
    };
    docker = record {
      maxLayers = int 124;
    };
    systems = (list str) // {default = [system];};
    process = record (command.fields
      // {
        environment = attrs str;
        workingDirectory = str // {default = "/";};
        user = str // {default = "65534:65534";};
      });
    initialization = record {
      steps = list (record (command.fields
        // {
          id = str;
          timeoutSeconds = int 0;
        }));
      budgetSeconds = int 0;
      startupAllowanceSeconds = int 30;
    };
    resources = record {
      cpuRequest = int 0;
      cpuLimit = int 0;
      memoryRequest = int 0;
      memoryLimit = int 0;
      replicas = record {
        min = int 1;
        max = int 1;
      };
      targetMetric = nullable str;
      placement = list str;
      strictSingleton = bool false;
    };
    probes = record {
      startup = probe;
      readiness = probe;
      liveness = probe;
    };
    restart = record {
      enabled = bool true;
      triggers = (list (enum ["unexpected-exit" "liveness-failure" "startup-failure"] "unexpected-exit")) // {default = ["unexpected-exit" "liveness-failure" "startup-failure"];};
      maxRetries = int 5;
      initialDelaySeconds = int 1;
      maxDelaySeconds = int 30;
      multiplier = int 2;
      jitter = bool true;
      continuousReadyResetSeconds = int 300;
    };
    shutdown = record {
      stopSignal = enum ["SIGTERM" "SIGINT" "SIGQUIT" "SIGHUP"] "SIGTERM";
      stopGracePeriodSeconds = int 30;
    };
    rollout = record {
      strategy = enum ["rolling"] "rolling";
      maxSurge = int 1;
      maxUnavailable = int 0;
      minReadySeconds = int 10;
      progressDeadlineSeconds = int 600;
      automaticRollback = bool true;
    };
    network = record {
      ports = attrs (record {
        port = int 0;
        protocol = enum ["tcp" "http" "grpc"] "tcp";
        exposure = enum ["private" "public"] "private";
      });
      privateConnections = list (record {
        sourceService = str;
        destinationService = str;
        destinationPort = str;
        protocol = enum ["tcp" "http" "grpc"] "tcp";
      });
      publicEgress = bool true;
      egressRestrictions = list str;
    };
    secrets = attrs (record {
      external = str;
      mode = enum ["file" "environment"] "file";
      target = str;
      required = bool true;
    });
    storage = attrs (record {
      mountPoint = str;
      lifecycle = enum ["ephemeral" "persistent"] "ephemeral";
      medium = enum ["disk" "memory"] "disk";
      sizeBytes = int 0;
      accessMode = enum ["readWriteOnce" "readOnlyMany" "readWriteMany"] "readWriteOnce";
      driverClass = str;
    });
    requiredCapabilities = list str;
  };
  root = config:
    record (fields
      // {
        oci = record {
          imageName = nullable str;
          # Allow one additional layer for image metadata within Docker's budget.
          maxLayers = int config.docker.maxLayers;
        };
      });
  # Every type accepts input at the module engine's check boundary. Its merge
  # validates instead, so lib.evalModules cannot print a rejected secret value.
  toType = shape:
    types.mkOptionType {
      name = "billet-${shape.name}";
      check = _: true;
      merge = loc: defs:
        if !(builtins.all (d: shape.check d.value) defs)
        then fail loc "expected ${shape.name}"
        else let
          inner =
            if shape.kind == "record"
            then
              types.submodule {
                freeformType = types.attrsOf types.raw;
                options = options shape.fields;
              }
            else if shape.kind == "attrs"
            then types.attrsOf (toType shape.item)
            else if shape.kind == "list"
            then types.listOf (toType shape.item)
            else if shape.kind == "nullable"
            then types.nullOr (toType shape.item)
            else null;
          values = map (d: d.value) defs;
        in
          if inner != null
          then inner.merge loc defs
          else if builtins.all (v: v == builtins.head values) values
          then builtins.head values
          else fail loc "conflicting definitions";
    };
  options = fields:
    lib.mapAttrs (_: shape:
      mkOption {
        type = toType shape;
        default = shape.default;
        description = "Billet v1 ${shape.name}; see the public IR contract.";
      })
    fields;
  unknown = loc: shape: value:
    if shape.kind == "record"
    then let
      keys = builtins.filter (k: k != "_module") (builtins.attrNames value);
      extra = builtins.filter (k: !(builtins.hasAttr k shape.fields)) keys;
    in
      if extra != []
      then fail (loc ++ [(builtins.head extra)]) "unknown field"
      else builtins.deepSeq (lib.mapAttrs (k: s: unknown (loc ++ [k]) s value.${k}) shape.fields) true
    else if shape.kind == "attrs"
    then builtins.deepSeq (lib.mapAttrs (k: v: unknown (loc ++ [k]) shape.item v) value) true
    else if shape.kind == "list"
    then builtins.deepSeq (lib.imap0 (i: v: unknown (loc ++ [(toString i)]) shape.item v) value) true
    else if shape.kind == "nullable" && value != null
    then unknown loc shape.item value
    else true;
in {
  module = {config, ...}: {
    freeformType = types.attrsOf types.raw;
    options = options (root config).fields;
  };
  checkUnknown = config: unknown [] (root config) config;
}
