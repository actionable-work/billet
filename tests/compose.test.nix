{
  pkgs,
  billetLib,
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
  compose = "${cli} --project-name billet-artifact -f ${bundle}/compose.yaml";
  helloEnv = ''env BILLET_SECRET_hello__database="$(cat /tmp/file-secret)" BILLET_SECRET_hello__token="$(cat /tmp/env-secret)"'';
  project = "${cli} --project-name billet-catalog-report -f ${catalogReport}/compose.yaml";
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
  nativeCommand = ''env BILLET_SECRET_db_Happ__shared="$(cat /tmp/file-secret)" BILLET_SECRET_worker__shared="$(cat /tmp/env-secret)" BILLET_SECRET_worker__optional= ${cli} --project-name billet-native -f ${native.bundle}/compose.yaml'';
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
in {
  "billet:compose-artifact" = pkgs.testers.runNixOSTest {
    name = "billet-compose-artifact";
    globalTimeout = 180;
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
      import hashlib
      import json

      machine.start()
      machine.wait_for_unit("docker.service")
      machine.succeed("cat /proc/sys/kernel/random/uuid >/tmp/file-secret; cat /proc/sys/kernel/random/uuid >/tmp/env-secret")

      def inspect(container):
          return json.loads(machine.succeed(f"${docker} inspect {container}"))[0]

      def containers(command, name):
          return machine.succeed(f"{command} ps --all --quiet {name}").split()

      machine.succeed("cmp ${fixture.manifest} ${bundle}/manifest.json")
      manifest = json.loads(machine.succeed("cat ${bundle}/manifest.json"))
      assert manifest["rollout"]["minReadySeconds"] == 23
      assert manifest["secrets"]["database"] == {
          "external": "runtime/database", "mode": "file",
          "target": "/run/secrets/database", "required": True,
      }
      rendered = json.loads(machine.succeed("cat ${bundle}/compose.yaml"))
      assert list(rendered["services"]) == ["hello"]
      hello = rendered["services"]["hello"]
      assert hello["image"] == "${reference}" and hello["pull_policy"] == "never"
      assert {"entrypoint", "command", "user", "working_dir"}.isdisjoint(hello)
      assert rendered["x-billet"] == {
          "manifest": "./manifest.json", "manifestDigest": "${fixture.manifestDigest}",
      }
      assert rendered["secrets"] == {"hello__database": {"environment": "BILLET_SECRET_hello__database"}}
      assert hello["secrets"] == [{
          "source": "hello__database", "target": "/run/secrets/database",
          "uid": "65534", "gid": "65534", "mode": 256,
      }]
      assert hello["environment"]["APP_TOKEN"].startswith("$" + "{BILLET_SECRET_hello__token:?")
      assert hello["environment"]["APP_OPTIONAL"] == "$" + "{BILLET_SECRET_hello__optional:-}"
      missing = machine.fail("env -u BILLET_SECRET_hello__token ${compose} config --quiet 2>&1")
      assert "BILLET_SECRET_hello__token" in missing
      assert "BILLET_SECRET_hello__token" in machine.fail("env BILLET_SECRET_hello__token= ${compose} config --quiet 2>&1")
      machine.succeed("${docker} image load --input ${bundle}/image.tar")
      image = json.loads(machine.succeed("${docker} image inspect ${reference}"))[0]
      assert image["Config"]["Labels"]["org.actionable-work.billet.manifest-digest"] == "${fixture.manifestDigest}"
      config = json.loads(machine.succeed("""${helloEnv} ${compose} config --format json"""))
      assert list(config["services"]) == [manifest["identity"]["name"]]
      assert config["services"]["hello"]["image"] == "${reference}"
      assert config["services"]["hello"]["pull_policy"] == "never"
      assert config["services"]["hello"]["environment"] == {
          "APP_TOKEN": machine.succeed("cat /tmp/env-secret").strip(), "APP_OPTIONAL": "",
      }
      assert "Hello from Billet" in machine.succeed("""${helloEnv} ${compose} up --no-build --exit-code-from hello 2>&1""")
      hello_id, = containers("""${helloEnv} ${compose}""", "hello")
      info = inspect(hello_id)
      assert info["RestartCount"] == 0
      assert "APP_TOKEN=" + machine.succeed("cat /tmp/env-secret").strip() in info["Config"]["Env"]
      assert "APP_OPTIONAL=" in info["Config"]["Env"]
      copied = machine.succeed(f"${docker} cp {hello_id}:/run/secrets/database - | tar -xOf -")
      assert copied == machine.succeed("cat /tmp/file-secret").strip()
      machine.succeed("""${helloEnv} ${compose} down --volumes""")
      assert machine.succeed("${docker} ps -aq").strip() == ""

      with subtest("independent Billets share the Compose network"):
          rendered = json.loads(machine.succeed("cat ${catalogReport}/compose.yaml"))
          parsed = json.loads(machine.succeed("${project} config --format json"))
          services = {"catalog", "report"}
          assert set(parsed["services"]) == services
          assert set(rendered["x-billet"]["services"]) == services
          for name in sorted(services):
              metadata = rendered["x-billet"]["services"][name]
              assert metadata["manifest"] == f"./manifests/{name}.json"
              manifest = machine.succeed(f"cat ${catalogReport}/manifests/{name}.json")
              assert json.loads(manifest)["identity"]["name"] == name
              digest = "sha256:" + hashlib.sha256(manifest.encode()).hexdigest()
              assert metadata["manifestDigest"] == digest
              image = parsed["services"][name]["image"]
              machine.succeed(f"${docker} image load --input ${catalogReport}/images/{name}.tar")
              inspection = json.loads(machine.succeed(f"${docker} image inspect {image}"))[0]
              assert inspection["Config"]["Labels"]["org.actionable-work.billet.manifest-digest"] == digest
              if name == "catalog":
                  assert inspection["Config"]["Entrypoint"] == ["${catalogExecutable}"]
          report = machine.succeed("${project} up --no-build --exit-code-from report 2>&1")
          expected = '{"items":[{"inStock":true,"sku":"notebook"}]}'
          assert expected in report, report
          machine.succeed("${project} down --volumes")
          assert machine.succeed("${docker} ps -aq").strip() == ""

      with subtest("Compose parses native directives and preserves manifest-only intent"):
          project_file = json.loads(machine.succeed("cat ${native.bundle}/compose.yaml"))
          config = json.loads(machine.succeed("""${nativeCommand} config --format json"""))
          services = config["services"]
          server = services["db-app"]
          client = services["worker"]
          limits = server["deploy"]["resources"]["limits"]
          reservations = server["deploy"]["resources"]["reservations"]
          assert float(limits["cpus"]) == 0.625 and int(limits["memory"]) == 67108864
          assert float(reservations["cpus"]) == 0.125 and int(reservations["memory"]) == 16777216
          assert (server["deploy"]["replicas"], client["deploy"]["replicas"], services["idle"]["deploy"]["replicas"]) == (1, 2, 0)
          assert (server["stop_signal"], server["stop_grace_period"]) == ("SIGINT", "7s")
          assert server["restart"] == "on-failure:2"
          assert client["restart"] == services["idle"]["restart"] == "no"
          assert project_file["services"]["db-app"]["healthcheck"]["test"][3] == "$$HOME"
          assert server["healthcheck"] == {
              "test": ["CMD", "${readiness}/bin/compose-ready", "", "$$HOME", "a; b"],
              "interval": "2s", "timeout": "1s", "retries": 4, "start_period": "6s",
          }
          assert client["healthcheck"]["test"] == ["CMD", "${pkgs.coreutils}/bin/true"]
          assert client["healthcheck"]["start_period"] == "15s"
          assert "healthcheck" not in services["failer"] and "healthcheck" not in services["idle"]
          assert set(client["depends_on"]) == {"db-app"}
          assert client["depends_on"]["db-app"]["condition"] == "service_healthy"
          assert set(config["networks"]) == {"billet-internal", "billet-egress"}
          assert config["networks"]["billet-internal"]["internal"]
          assert not config["networks"]["billet-egress"].get("internal", False)
          assert set(server["networks"]) == {"billet-internal", "billet-egress"}
          assert set(client["networks"]) == {"billet-internal"}
          assert server["ports"][0]["target"] == 8080 and server["ports"][0]["protocol"] == "tcp"
          assert server["expose"] == ["9090"]
          assert client["expose"] == ["8081"] and "ports" not in client
          assert set(config["secrets"]) == {"db_Happ__shared", "worker__optional", "worker__shared"}
          assert set(config["volumes"]) == {"db_Happ__state", "worker__state"}
          assert len(services) == 4
          worker_ir = json.loads(machine.succeed("cat ${native.bundle}/manifests/worker.json"))
          server_ir = json.loads(machine.succeed("cat ${native.bundle}/manifests/db-app.json"))
          idle_ir = json.loads(machine.succeed("cat ${native.bundle}/manifests/idle.json"))
          assert worker_ir["resources"]["replicas"]["max"] == 3
          assert worker_ir["resources"]["targetMetric"] == "fixture-metric"
          assert worker_ir["resources"]["placement"] == ["fixture-zone"]
          assert idle_ir["resources"]["strictSingleton"]
          assert len(worker_ir["network"]["privateConnections"]) == 2
          assert server_ir["rollout"]["minReadySeconds"] == 42
          assert server_ir["network"]["egressRestrictions"] == ["fixture-restriction"]
          assert server_ir["initialization"]["steps"][0]["id"] == "prepare"
          assert server_ir["storage"]["state"]["driverClass"] == "fixture-driver"
          assert server_ir["storage"]["state"]["sizeBytes"] == 1048576
          assert worker_ir["storage"]["state"]["accessMode"] == "readOnlyMany"
          assert server_ir["secrets"]["shared"]["external"] == "runtime/shared"
          assert {"init", "post_start", "pre_stop"}.isdisjoint(server)
          assert {"placement", "update_config", "rollback_config", "restart_policy"}.isdisjoint(project_file["services"]["db-app"]["deploy"])
          assert {"placement", "update_config"}.isdisjoint(project_file["services"]["worker"]["deploy"])

          report = json.loads(r"""${builtins.unsafeDiscardStringContext (builtins.toJSON native.capabilityReport)}""")
          assert report["canRender"]
          assert set(report["supportedCapabilities"]) == {
              "resources", "replicas", "shutdown", "restart", "probes", "runtime-secrets", "network-ports",
              "network-egress-isolation", "readiness-dependencies", "storage-ephemeral-memory",
              "storage-ephemeral-disk", "storage-persistent-disk",
          }
          assert "probes" not in report["services"]["idle"]["supportedCapabilities"]
          assert set(report["services"]["db-app"]["supportedCapabilities"]) == {
              "resources", "replicas", "shutdown", "restart", "probes", "runtime-secrets", "network-ports",
              "storage-ephemeral-memory", "storage-ephemeral-disk", "storage-persistent-disk",
          }
          assert set(report["requiredCapabilities"]) == {
              capability for member in report["services"].values() for capability in member["requiredCapabilities"]
          }
          diagnostics = {(d["code"], d["field"], d["severity"]) for d in report["diagnostics"]}
          for code, field in (
              ("ComposeCPUReservation", "db-app.resources.cpuRequest"),
              ("ComposeReplicaRange", "worker.resources.replicas.max"),
              ("UnsupportedComposeNetworkProbe", "worker.probes.readiness.type"),
              ("UnsupportedComposeNetworkProbe", "failer.probes.liveness.type"),
              ("UnsupportedComposeNetworkProbe", "idle.probes.readiness.type"),
              ("UnsupportedComposeInitialization", "db-app.initialization.steps"),
              ("ComposeInternalPort", "worker.network.ports.http.exposure"),
              ("ComposeOptionalFileSecret", "worker.secrets.optional.required"),
              ("ComposeDiskQuota", "db-app.storage.work.sizeBytes"),
              ("ComposeDiskQuota", "db-app.storage.state.sizeBytes"),
          ):
              assert (code, f"services.{field}", "warning") in diagnostics
          restart = server_ir["restart"]
          assert (restart["initialDelaySeconds"], restart["maxDelaySeconds"], restart["multiplier"]) == (1, 30, 2)
          assert restart["jitter"] and restart["continuousReadyResetSeconds"] == 300

          isolated = json.loads(machine.succeed("${cli} -p billet-isolated -f ${isolated.dockerCompose.file} config --format json"))
          assert isolated["services"]["isolated"]["restart"] == "no"
          assert set(isolated["services"]["isolated"]["networks"]) == {"billet-internal"}
          assert list(isolated["networks"]) == ["billet-internal"] and isolated["networks"]["billet-internal"]["internal"]

          cyclic = json.loads(machine.succeed("${cli} -p billet-cycle -f ${cyclic.file} config --format json"))
          assert all("depends_on" not in member for member in cyclic["services"].values())
          cycle_report = json.loads(r"""${builtins.unsafeDiscardStringContext (builtins.toJSON cyclic.capabilityReport)}""")
          assert cycle_report["canRender"]
          assert {d["field"] for d in cycle_report["diagnostics"] if d["code"] == "ComposeReadinessCycle"} == {
              "services.left.network.privateConnections", "services.right.network.privateConnections",
          }

      with subtest("Docker enforces the native Compose directives"):
          command = """${nativeCommand}"""
          machine.succeed("for archive in ${native.bundle}/images/*.tar; do ${docker} image load --input \"$archive\"; done")
          machine.succeed(f"{command} up --no-build --detach")
          db, = containers(command, "db-app")
          workers = containers(command, "worker")
          failer, = containers(command, "failer")
          assert len(workers) == 2 and containers(command, "idle") == []

          db_info = inspect(db)
          host = db_info["HostConfig"]
          assert host["NanoCpus"] == 625000000
          assert host["Memory"] == 67108864
          assert host["MemoryReservation"] == 16777216
          assert db_info["Config"]["StopSignal"] == "SIGINT" and db_info["Config"]["StopTimeout"] == 7
          assert "MARKER=from-image" in db_info["Config"]["Env"]
          assert db_info["State"]["Health"]["Status"] == "healthy"
          health = db_info["Config"]["Healthcheck"]
          assert health["Test"] == ["CMD", "${readiness}/bin/compose-ready", "", "$HOME", "a; b"]
          assert (health["Interval"], health["Timeout"], health["Retries"], health["StartPeriod"]) == (
              2000000000, 1000000000, 4, 6000000000,
          )
          port = machine.succeed(f"{command} port db-app 8080").splitlines()[0].rsplit(":", 1)[1]
          assert expected in machine.succeed(f"${pkgs.curl}/bin/curl -fsS http://127.0.0.1:{port}/items.json")
          assert db_info["NetworkSettings"]["Ports"]["9090/tcp"] is None
          assert set(db_info["NetworkSettings"]["Networks"]) == {"billet-native_billet-egress", "billet-native_billet-internal"}
          route = machine.succeed(f"${docker} exec {db} ${pkgs.coreutils}/bin/cat /proc/net/route")
          assert any(line.split()[1] == "00000000" for line in route.splitlines()[1:])
          machine.succeed(f"${docker} run --detach --name internal-port-probe --network billet-native_billet-internal --publish 8080 {db_info['Config']['Image']}")
          assert not inspect("internal-port-probe")["NetworkSettings"]["Ports"].get("8080/tcp")
          machine.succeed("${docker} rm --force internal-port-probe")

          mounts = {mount["Target"]: mount for mount in host["Mounts"]}
          assert mounts["/scratch"]["Type"] == "tmpfs"
          assert mounts["/scratch"]["TmpfsOptions"]["SizeBytes"] == 1048576
          db_mounts = {mount["Destination"]: mount for mount in db_info["Mounts"]}
          assert db_mounts["/work"]["Type"] == "volume"
          assert db_mounts["/work"]["Name"] not in {"billet-native_db_Happ__state", "billet-native_worker__state"}
          assert db_mounts["/state"]["Name"] == "billet-native_db_Happ__state"
          assert machine.succeed(f"${docker} exec {db} ${pkgs.coreutils}/bin/cat /etc/billet-test/shared") == machine.succeed("cat /tmp/file-secret").strip()
          assert machine.succeed(f"${docker} exec {db} ${pkgs.coreutils}/bin/stat -c '%u:%g:%a' /etc/billet-test/shared").strip() == "65534:65534:400"

          for worker in workers:
              info = inspect(worker)
              assert info["State"]["Running"]
              assert expected in machine.succeed(f"${docker} logs {worker}")
              assert info["HostConfig"]["RestartPolicy"]["Name"] == "no"
              assert set(info["NetworkSettings"]["Networks"]) == {"billet-native_billet-internal"}
              assert info["NetworkSettings"]["Ports"]["8081/tcp"] is None
              route = machine.succeed(f"${docker} exec {worker} ${pkgs.coreutils}/bin/cat /proc/net/route")
              assert all(line.split()[1] != "00000000" for line in route.splitlines()[1:])
              assert machine.succeed(f"${docker} exec {worker} ${pkgs.coreutils}/bin/cat /etc/billet-test/shared") == machine.succeed("cat /tmp/env-secret").strip()
              machine.fail(f"${docker} exec {worker} ${pkgs.coreutils}/bin/test -e /etc/billet-test/optional")
              volume, = (mount for mount in info["Mounts"] if mount["Destination"] == "/state")
              assert volume["Name"] == "billet-native_worker__state" and not volume["RW"]

          machine.wait_until_succeeds(f"${docker} inspect --format '{{{{.State.Status}}}}:{{{{.RestartCount}}}}:{{{{.State.ExitCode}}}}' {failer} | grep -qx exited:2:7")
          assert inspect(failer)["HostConfig"]["RestartPolicy"] == {"Name": "on-failure", "MaximumRetryCount": 2}
          machine.succeed(f"{command} down")
          machine.succeed("${docker} volume inspect billet-native_db_Happ__state billet-native_worker__state")
          machine.succeed(f"{command} down --volumes")
          assert machine.succeed("${docker} ps -aq").strip() == ""
    '';
  };
}
