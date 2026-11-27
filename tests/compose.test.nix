{
  pkgs,
  billetLib,
  checkers,
  catalogReport,
  catalogExecutable,
}: let
  inherit (pkgs) lib;
  hello = import ../examples/hello/application.nix {inherit pkgs;};
  make = module:
    billetLib.mkBillet {
      inherit pkgs;
      modules = [module];
    };
  fixture = billetLib.mkBillet {
    inherit pkgs;
    modules = [
      ../examples/hello/application.nix
      {
        rollout.minReadySeconds = 23;
        secrets.database = {
          external = "runtime/database";
          target = "/run/secrets/database";
        };
        secrets.token = {
          external = "runtime/token";
          mode = "environment";
          target = "APP_TOKEN";
        };
        secrets.optional = {
          external = "runtime/optional";
          mode = "environment";
          target = "APP_OPTIONAL";
          required = false;
        };
      }
    ];
  };
  bundle = fixture.dockerCompose.bundle;
  cli = "${pkgs.docker-compose}/bin/docker-compose";
  docker = "${pkgs.docker-client}/bin/docker";
  reference = fixture.ociImage.imageRefUnsafe;
  server = pkgs.writeShellScriptBin "compose-server" ''
    ${pkgs.coreutils}/bin/sleep 3
    exec ${catalogExecutable}
  '';
  readiness = pkgs.writeShellScriptBin "compose-ready" ''
    test "$#" -eq 3 && test -z "$1" && test "$2" = '$HOME' && test "$3" = 'a; b' || exit 1
    exec ${pkgs.curl}/bin/curl --fail --silent http://127.0.0.1:8080/items.json
  '';
  client = pkgs.writeShellScriptBin "compose-client" ''
    ${pkgs.curl}/bin/curl --fail --silent --show-error http://db-app:8080/items.json || exit 1
    exec ${pkgs.coreutils}/bin/sleep infinity
  '';
  failure = pkgs.writeShellScriptBin "compose-failure" "exit 7";
  state = {
    lifecycle = "persistent";
    mountPoint = "/state";
    sizeBytes = 1048576;
    driverClass = "fixture-driver";
  };
  sharedSecret = {
    external = "runtime/shared";
    target = "/etc/billet-test/shared";
  };
  dbApp = make (lib.recursiveUpdate hello {
    identity.name = "db-app";
    process = {
      package = server;
      executable = "bin/compose-server";
      argv = [];
      environment.MARKER = "from-image";
    };
    resources.cpuLimit = 625;
    resources.cpuRequest = 125;
    shutdown = {
      stopSignal = "SIGINT";
      stopGracePeriodSeconds = 7;
    };
    restart.maxRetries = 2;
    probes = {
      readiness = {
        intervalSeconds = 2;
        timeoutSeconds = 1;
        failureThreshold = 4;
        command = {
          package = readiness;
          executable = "bin/compose-ready";
          argv = ["" "$HOME" "a; b"];
        };
      };
      liveness.command = {
        package = pkgs.coreutils;
        executable = "bin/false";
      };
      startup = {
        intervalSeconds = 3;
        failureThreshold = 2;
        command = {
          package = pkgs.coreutils;
          executable = "bin/false";
        };
      };
    };
    network.ports = {
      http = {
        port = 8080;
        protocol = "http";
        exposure = "public";
      };
      metrics.port = 9090;
    };
    network.egressRestrictions = ["fixture-restriction"];
    secrets.shared = sharedSecret;
    storage = {
      inherit state;
      scratch = {
        medium = "memory";
        mountPoint = "/scratch";
        sizeBytes = 1048576;
        driverClass = "fixture-tmpfs";
      };
      work = {
        mountPoint = "/work";
        sizeBytes = 1048576;
        driverClass = "fixture-local";
      };
    };
    initialization = {
      steps = [
        {
          id = "prepare";
          package = failure;
          executable = "bin/compose-failure";
          timeoutSeconds = 1;
        }
      ];
      budgetSeconds = 1;
    };
    rollout.minReadySeconds = 42;
  });
  worker = make (lib.recursiveUpdate hello {
    identity.name = "worker";
    process = {
      package = client;
      executable = "bin/compose-client";
      argv = [];
    };
    resources.replicas = {
      min = 2;
      max = 3;
    };
    resources.targetMetric = "fixture-metric";
    resources.placement = ["fixture-zone"];
    restart.maxRetries = 0;
    shutdown.stopGracePeriodSeconds = 1;
    probes = {
      readiness = {
        type = "http";
        port = "http";
      };
      liveness.command = {
        package = pkgs.coreutils;
        executable = "bin/true";
      };
    };
    initialization.startupAllowanceSeconds = 15;
    network = {
      publicEgress = false;
      ports.http = {
        port = 8081;
        protocol = "http";
        exposure = "public";
      };
      privateConnections = [
        {
          sourceService = "worker";
          destinationService = "db-app";
          destinationPort = "http";
          protocol = "http";
        }
        {
          sourceService = "worker";
          destinationService = "remote";
          destinationPort = "http";
          protocol = "http";
        }
      ];
    };
    secrets = {
      shared = sharedSecret;
      optional = {
        external = "runtime/optional";
        target = "/etc/billet-test/optional";
        required = false;
      };
    };
    storage.state = state // {accessMode = "readOnlyMany";};
  });
  failer = make (lib.recursiveUpdate hello {
    identity.name = "failer";
    process = {
      package = failure;
      executable = "bin/compose-failure";
      argv = [];
    };
    probes.liveness = {
      type = "tcp";
      port = "grpc";
    };
    network.ports.grpc = {
      port = 9091;
      protocol = "grpc";
    };
    restart.maxRetries = 2;
  });
  idle = make (lib.recursiveUpdate hello {
    identity.name = "idle";
    resources = {
      replicas = {
        min = 0;
        max = 0;
      };
      strictSingleton = true;
    };
    rollout.maxSurge = 0;
    rollout.maxUnavailable = 1;
    restart.triggers = ["startup-failure"];
    probes.readiness = {
      type = "grpc";
      port = "api";
    };
    network.ports.api = {
      port = 9092;
      protocol = "grpc";
    };
  });
  native =
    (billetLib.mkBilletBundle {
      inherit pkgs;
      billets = {
        db-app = dbApp;
        inherit worker failer idle;
      };
    }).dockerCompose;
  isolated = make (lib.recursiveUpdate hello {
    identity.name = "isolated";
    network.publicEgress = false;
    restart.enabled = false;
  });
  peer = name: destination:
    make (lib.recursiveUpdate hello {
      identity.name = name;
      probes.readiness.command = {
        package = pkgs.coreutils;
        executable = "bin/true";
      };
      network = {
        ports.connection.port = 8080;
        privateConnections = [
          {
            sourceService = name;
            destinationService = destination;
            destinationPort = "connection";
          }
        ];
      };
    });
  cyclic =
    (billetLib.mkBilletBundle {
      inherit pkgs;
      billets = {
        left = peer "left" "right";
        right = peer "right" "left";
      };
    }).dockerCompose;
  upgradeApp = pkgs.writeShellScriptBin "compose-upgrade" ''
    trap 'exit 0' INT
    echo "BILLET_UPGRADE $1"
    while true; do ${pkgs.coreutils}/bin/sleep 1; done
  '';
  # Two versions of one Billet that differ in version, argv and image tag.
  upgrade = version: argument:
    make (lib.recursiveUpdate hello {
      identity = {
        name = "upgrade";
        inherit version;
      };
      process = {
        package = upgradeApp;
        executable = "bin/compose-upgrade";
        argv = [argument];
      };
      shutdown = {
        stopSignal = "SIGINT";
        stopGracePeriodSeconds = 5;
      };
    });
  upgradeV1 = upgrade "1.0.0" "v1";
  upgradeV2 = upgrade "2.0.0" "v2";
  report = value: builtins.unsafeDiscardStringContext (builtins.toJSON value);
  parameters = pkgs.writeText "compose-artifact.json" (builtins.toJSON {
    inherit bundle reference cli docker catalogReport catalogExecutable;
    coreutils = "${pkgs.coreutils}";
    curl = "${pkgs.curl}/bin/curl";
    readiness = "${readiness}/bin/compose-ready";
    fixtureManifest = "${fixture.manifest}";
    digest = fixture.manifestDigest;
    nativeBundle = "${native.bundle}";
    nativeReport = builtins.fromJSON (report native.capabilityReport);
    isolatedFile = "${isolated.dockerCompose.file}";
    cyclicFile = "${cyclic.file}";
    cyclicReport = builtins.fromJSON (report cyclic.capabilityReport);
    upgradeV1File = "${upgradeV1.dockerCompose.file}";
    upgradeV2File = "${upgradeV2.dockerCompose.file}";
    upgradeV1Image = "${upgradeV1.dockerImage}";
    upgradeV2Image = "${upgradeV2.dockerImage}";
    upgradeV1Ref = upgradeV1.ociImage.imageRefUnsafe;
    upgradeV2Ref = upgradeV2.ociImage.imageRefUnsafe;
  });
in {
  "billet:compose-artifact" = pkgs.testers.runNixOSTest {
    name = "billet-compose-artifact";
    # Loading the layered archives can dominate the run on slower builders.
    globalTimeout = 360;
    qemu.forceAccel = true;
    passthru.bloomery = [
      "BILLET-IR-TARGETS-006"
      "BILLET-IR-TARGETS-007"
      "BILLET-IR-TARGETS-008"
      "BILLET-IR-TARGETS-009"
      "BILLET-IR-TARGETS-010"
      "BILLET-IR-TARGETS-011"
      "BILLET-IR-TARGETS-012"
      "BILLET-IR-TARGETS-013"
      "BILLET-IR-TARGETS-014"
      "BILLET-IR-TARGETS-015"
      "BILLET-IR-TARGETS-016"
      "BILLET-IR-TARGETS-017"
      "BILLET-IR-TARGETS-024"
      "BILLET-IR-TARGETS-026"
      "BILLET-IR-TARGETS-027"
      "BILLET-IR-TARGETS-028"
      "BILLET-IR-TARGETS-029"
      "BILLET-IR-TARGETS-030"
      "BILLET-IR-TARGETS-031"
      "BILLET-IR-TARGETS-032"
      "BILLET-IR-TARGETS-033"
      "BILLET-IR-TARGETS-034"
      "BILLET-IR-TARGETS-035"
      "BILLET-IR-TARGETS-036"
      "BILLET-IR-TARGETS-037"
      "BILLET-IR-TARGETS-038"
      "BILLET-IR-TARGETS-039"
      "BILLET-IR-TARGETS-040"
      "BILLET-IR-TARGETS-041"
      "BILLET-IR-TARGETS-042"
      "BILLET-IR-TARGETS-043"
      "BILLET-IR-TARGETS-044"
      "BILLET-IR-TARGETS-045"
      "BILLET-IR-TARGETS-046"
      "BILLET-IR-TARGETS-047"
      "BILLET-IR-TARGETS-048"
      "BILLET-IR-TARGETS-049"
      "BILLET-IR-TARGETS-050"
      "BILLET-IR-TARGETS-051"
      "BILLET-IR-TARGETS-052"
      "BILLET-IR-TARGETS-053"
      "BILLET-IR-TARGETS-054"
      "BILLET-IR-TARGETS-055"
      "BILLET-IR-TARGETS-056"
      "BILLET-IR-TARGETS-057"
      "BILLET-IR-TARGETS-058"
      "BILLET-IR-TARGETS-059"
      "BILLET-IR-TARGETS-060"
      "BILLET-IR-TARGETS-061"
      "BILLET-IR-TARGETS-062"
      "BILLET-IR-TARGETS-063"
      "BILLET-IR-TARGETS-064"
      "BILLET-IR-TARGETS-065"
      "BILLET-IR-TARGETS-066"
      "BILLET-IR-TARGETS-067"
      "BILLET-IR-TARGETS-068"
      "BILLET-IR-TARGETS-069"
      "BILLET-IR-TARGETS-070"
      "BILLET-IR-TARGETS-071"
      "BILLET-IR-TARGETS-072"
      "BILLET-IR-TARGETS-073"
      "BILLET-IR-TARGETS-074"
      "BILLET-IR-TARGETS-075"
      "BILLET-IR-TARGETS-076"
      "BILLET-IR-TARGETS-077"
      "BILLET-IR-TARGETS-078"
      "BILLET-IR-TARGETS-079"
      "BILLET-IR-TARGETS-080"
      "BILLET-IR-TARGETS-081"
      "BILLET-IR-TARGETS-082"
      "BILLET-IR-TARGETS-083"
      "BILLET-IR-TARGETS-084"
      "BILLET-IR-TARGETS-085"
      "BILLET-IR-TARGETS-092"
      "BILLET-IR-TARGETS-093"
    ];
    nodes.machine = {
      virtualisation = {
        memorySize = 2048;
        cores = 2;
        diskSize = 4096;
        docker.enable = true;
      };
    };
    testScript = ''
      machine.start()
      machine.wait_for_unit("docker.service")
      machine.succeed("${checkers.compose}/bin/billet-vm-compose compose-artifact ${parameters} >&2", timeout=900)
    '';
  };
}
