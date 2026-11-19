{
  pkgs,
  billetLib,
}: let
  lib = pkgs.lib;
  base = import ../examples/hello/application.nix {inherit pkgs;};
  leaf = pkgs.writeText "billet-runtime-leaf" "transitive runtime data\n";
  middle = pkgs.writeText "billet-runtime-middle" "${leaf}\n";
  data = pkgs.writeText "billet-config-data" "non-secret configuration\n";
  app = pkgs.writeShellScriptBin "application" ''exec ${pkgs.coreutils}/bin/cat ${middle}'';
  initPackage = pkgs.writeShellScriptBin "initialize" "exit 0";
  probePackage = pkgs.writeShellScriptBin "probe" "exit 0";
  full = lib.recursiveUpdate base {
    resources.placement = ["zone-b" "zone-a" "zone-b"];
    requiredCapabilities = ["fixture-extra" "fixture-extra"];
    process = {
      package = app;
      executable = "bin/application";
      argv = ["" "two words" "$(not-a-shell)" "a;b"];
      environment.DATA = "${data}";
    };
    initialization = {
      steps = [
        {
          id = "prepare";
          package = initPackage;
          executable = "bin/initialize";
          argv = ["init"];
          timeoutSeconds = 2;
        }
      ];
      budgetSeconds = 2;
    };
    probes.readiness = {
      type = "exec";
      command = {
        package = probePackage;
        executable = "bin/probe";
      };
    };
    network.ports.web = {
      port = 8080;
      protocol = "http";
    };
    secrets = {
      database = {
        external = "runtime/database";
        target = "/run/secrets/database";
      };
      token = {
        external = "runtime/token";
        mode = "environment";
        target = "APP_TOKEN";
      };
    };
    storage.scratch = {
      mountPoint = "/tmp/work";
      sizeBytes = 4096;
      medium = "memory";
      driverClass = "tmpfs";
    };
  };
  evaluate = module:
    billetLib.mkBillet {
      inherit pkgs;
      modules = [module];
    };
  invalid = {
    schemaVersion = base // {schemaVersion = 0;};
    unknown = base // {applications = ["another"];};
    wrongType = lib.recursiveUpdate base {resources.cpuLimit = "DO-NOT-ECHO-SECRET";};
    imageName = lib.recursiveUpdate base {identity.imageName = "DO-NOT-ECHO-SECRET";};
    imageNameDefault = lib.recursiveUpdate base {identity.name = "a..b";};
    inlineSecret = lib.recursiveUpdate full {secrets.database.value = "DO-NOT-ECHO-SECRET";};
    secretType = lib.recursiveUpdate full {secrets.database.external = {value = "DO-NOT-ECHO-SECRET";};};
    secretContext = lib.recursiveUpdate full {secrets.database.external = "${data}";};
    cpu = lib.recursiveUpdate base {resources.cpuRequest = 1001;};
    memory = lib.recursiveUpdate base {resources.memoryLimit = -1;};
    executable = lib.recursiveUpdate base {process.executable = "bin/../hello";};
    noPackage = lib.recursiveUpdate base {process.package = null;};
    system = base // {systems = ["unsupported-system"];};
    ports = lib.recursiveUpdate full {network.ports.other.port = 8080;};
    probePort = lib.recursiveUpdate base {
      probes.readiness = {
        type = "tcp";
        port = "absent";
      };
    };
    probeType = lib.recursiveUpdate base {probes.readiness.type = "exec";};
    mount = lib.recursiveUpdate full {
      storage.other = {
        mountPoint = "/tmp/work/child";
        sizeBytes = 1;
        driverClass = "local";
      };
    };
    scratch = lib.recursiveUpdate full {storage.scratch.sizeBytes = 100000000;};
    scratchOverflow = lib.recursiveUpdate full {
      resources.memoryLimit = 9223372036854775807;
      storage.extra = {
        mountPoint = "/extra";
        medium = "memory";
        sizeBytes = 9223372036854775807;
        driverClass = "tmpfs";
      };
    };
    persistentMemory = lib.recursiveUpdate full {storage.scratch.lifecycle = "persistent";};
    secretCollision = lib.recursiveUpdate full {process.environment.APP_TOKEN = "public";};
    secretMount = lib.recursiveUpdate full {secrets.database.target = "/tmp/work/key";};
    duplicateSecret = lib.recursiveUpdate full {
      secrets.token = {
        mode = "file";
        target = "/run/secrets/database";
      };
    };
    initBudget = lib.recursiveUpdate full {initialization.budgetSeconds = 1;};
    duplicateInit = lib.recursiveUpdate full {initialization.steps = full.initialization.steps ++ full.initialization.steps;};
    retry = lib.recursiveUpdate base {restart.maxRetries = -1;};
    retryDelay = lib.recursiveUpdate base {restart.maxDelaySeconds = 0;};
    multiplier = lib.recursiveUpdate base {restart.multiplier = 1;};
    grace = lib.recursiveUpdate base {shutdown.stopGracePeriodSeconds = -1;};
    rollout = lib.recursiveUpdate base {rollout.progressDeadlineSeconds = 0;};
    rolloutProgress = lib.recursiveUpdate base {
      rollout = {
        maxSurge = 0;
        maxUnavailable = 0;
      };
    };
    singleton = lib.recursiveUpdate base {resources.strictSingleton = true;};
    replicas = lib.recursiveUpdate base {
      resources.replicas = {
        min = 2;
        max = 1;
      };
    };
  };
in {
  inherit base full leaf middle data app initPackage probePackage invalid evaluate;
  sample = evaluate full;
  validation = {
    service = evaluate (lib.recursiveUpdate base {
      identity.name = "trap";
      process = {
        package = pkgs.runCommand "billet-validation-must-not-build" {} "exit 99";
        user = "named-user";
      };
    });
    invalid = evaluate (lib.recursiveUpdate invalid.cpu {identity.name = "invalid";});
  };
}
