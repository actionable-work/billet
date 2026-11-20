# Qualification for the stateful guestbook example. See
# PUBLIC/design/examples.md.
{
  pkgs,
  billetLib,
  harness,
  guestbook,
  guestbookChecks,
}: let
  inherit (pkgs) lib;
  modules = ../examples/guestbook/modules;
  base = billetLib.mkBillet {
    inherit pkgs;
    modules = [(modules + "/guestbook.nix")];
  };
  inherit (guestbook) dev prod;
  devApp = dev.billets.guestbook.ir;
  prodApp = prod.billets.guestbook.ir;
  members = ["guestbook" "postgres"];
  checkNames = lib.concatMap (environment: ["billet:${environment}:validate"] ++ map (name: "billet:${environment}:${name}:validate") members) ["dev" "prod"];
  expectedChecks = lib.concatMap (environment: let
    bundle = guestbook.${environment};
  in
    [bundle.validationCheck] ++ map (name: bundle.billets.${name}.validationCheck) members) ["dev" "prod"];
  marker = name: attrs: pkgs.runCommand name attrs ''touch "$out"'';

  docker = "${pkgs.docker-client}/bin/docker";
  compose = let
    secrets = lib.concatStringsSep " " [
      ''BILLET_SECRET_guestbook__databasePassword="$(cat /tmp/db-password)"''
      ''BILLET_SECRET_guestbook__sessionKey="$(cat /tmp/session-key)"''
      ''BILLET_SECRET_postgres__password="$(cat /tmp/db-password)"''
    ];
  in "env ${secrets} ${pkgs.docker-compose}/bin/docker-compose --project-name guestbook -f ${dev.dockerCompose.bundle}/compose.yaml";
  json = value: builtins.unsafeDiscardStringContext (builtins.toJSON value);

  # Fixture secrets are generated inside the VM and handed to the consumer;
  # they never reach Nix evaluation.
  common = ''
    import hashlib
    import hmac
    import json
    import shlex

    def request(url, data=None):
        command = f"curl -sS -w '\\n%{{http_code}}' {url}"
        if data is not None:
            command += " -H 'Content-Type: application/json' --data " + shlex.quote(json.dumps(data))
        body, status = machine.succeed(command).rsplit("\n", 1)
        return int(status), json.loads(body)

    def signed(key, entry):
        text = json.dumps([entry["id"], entry["author"], entry["message"]], separators=(",", ":")).encode()
        return hmac.new(key.encode(), text, hashlib.sha256).hexdigest()

    def entries(url, key):
        status, body = request(f"{url}/entries")
        assert status == 200, body
        for entry in body["entries"]:
            assert entry["signature"] == signed(key, entry), entry
        return [(entry["author"], entry["message"]) for entry in body["entries"]]

    # Wait until every listed replica is ready and serves entries.
    def settle(urls):
        for url in urls:
            machine.wait_until_succeeds(f"curl -fsS {url}/readyz && curl -fsS {url}/entries", timeout=120)

    machine.succeed("head -c 24 /dev/urandom | base64 -w0 > /tmp/db-password")
    machine.succeed("head -c 32 /dev/urandom | base64 -w0 > /tmp/session-key")
    password = machine.succeed("cat /tmp/db-password")
    key = machine.succeed("cat /tmp/session-key")
  '';
in
  {
    "billet:guestbook-validation" = assert builtins.attrNames guestbook == ["dev" "prod"];
    assert lib.all (environment: builtins.attrNames guestbook.${environment}.billets == members) ["dev" "prod"];
    assert lib.sort builtins.lessThan (builtins.attrNames guestbookChecks) == lib.sort builtins.lessThan checkNames;
    assert map (name: guestbookChecks.${name}.drvPath) checkNames == map (check: check.drvPath) expectedChecks;
      pkgs.runCommand "billet-guestbook-validation" {
        passthru.bloomery = ["BILLET-PUBLIC-EXAMPLES-001"];
        checks = map (name: guestbookChecks.${name}) checkNames;
      } ''
        for check in $checks; do
          test -s "$check"
        done
        touch "$out"
      '';

    # The base keeps its mkDefault values until an overlay sets them plainly.
    "billet:guestbook-overlay-defaults" = assert base.ir.resources.cpuLimit == 500 && base.ir.process.environment.GUESTBOOK_LOG_LEVEL == "warning";
    assert devApp.resources.cpuLimit == 250 && devApp.resources.memoryLimit == 67108864;
    assert devApp.resources.cpuRequest == base.ir.resources.cpuRequest;
    assert devApp.process.environment.GUESTBOOK_LOG_LEVEL == "debug" && devApp.rollout.minReadySeconds == 0;
    assert prodApp.resources.cpuLimit
    == 1000
    && prodApp.resources.replicas
    == {
      min = 2;
      max = 2;
    };
    assert prodApp.process.environment.GUESTBOOK_LOG_LEVEL == "info" && prodApp.rollout.minReadySeconds == 10;
      marker "billet-guestbook-overlay-defaults" {passthru.bloomery = ["BILLET-PUBLIC-EXAMPLES-002"];};

    # mkForce replaces a plain base value; other plain base values pass through.
    "billet:guestbook-overlay-force" = assert base.ir.shutdown.stopGracePeriodSeconds == 15;
    assert devApp.shutdown.stopGracePeriodSeconds == 15;
    assert prodApp.shutdown.stopGracePeriodSeconds == 30;
    assert devApp.network == prodApp.network && devApp.secrets == prodApp.secrets && devApp.probes == prodApp.probes;
    assert devApp.initialization == prodApp.initialization;
      marker "billet-guestbook-overlay-force" {passthru.bloomery = ["BILLET-PUBLIC-EXAMPLES-003"];};

    "billet:guestbook-overlay-conflict" =
      pkgs.runCommand "billet-guestbook-overlay-conflict" {
        passthru.bloomery = ["BILLET-PUBLIC-EXAMPLES-004"];
        nativeBuildInputs = [pkgs.nix];
        source = ../.;
        nixpkgsSource = pkgs.path;
        system = pkgs.stdenv.hostPlatform.system;
      } ''
        ${harness}/bin/billet-acceptance diagnose overlayConflict process.environment.GUESTBOOK_LOG_LEVEL "conflicting definitions"
        touch "$out"
      '';

    "billet:guestbook-image-budget" = assert devApp.oci == {imageName = "guestbook";};
      pkgs.runCommand "billet-guestbook-image-budget" {
        passthru.bloomery = ["BILLET-PUBLIC-EXAMPLES-005"];
        nativeBuildInputs = [pkgs.jq];
        descriptor = dev.billets.guestbook.closureDescriptor;
        image = dev.billets.guestbook.ociImage;
      } ''
        paths=$(jq '.paths | length' "$descriptor/descriptor.json")
        layers=$(jq '.layers | length' "$image")
        echo "closure paths: $paths, image layers: $layers"
        test "$paths" -gt 16
        test "$layers" -le 17
        touch "$out"
      '';
  }
  // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    "billet:guestbook-compose" = pkgs.testers.runNixOSTest {
      name = "billet-guestbook-compose";
      globalTimeout = 900;
      qemu.forceAccel = true;
      passthru.bloomery = [
        "BILLET-PUBLIC-EXAMPLES-006"
        "BILLET-PUBLIC-EXAMPLES-007"
        "BILLET-PUBLIC-EXAMPLES-008"
        "BILLET-PUBLIC-EXAMPLES-009"
        "BILLET-PUBLIC-EXAMPLES-010"
        "BILLET-PUBLIC-EXAMPLES-011"
        "BILLET-PUBLIC-EXAMPLES-012"
        "BILLET-PUBLIC-EXAMPLES-020"
        "BILLET-PUBLIC-EXAMPLES-021"
      ];
      nodes.machine = {
        virtualisation = {
          memorySize = 3072;
          cores = 2;
          diskSize = 8192;
          docker.enable = true;
        };
        environment.systemPackages = [pkgs.curl];
      };
      testScript = ''
        ${common}
        machine.wait_for_unit("docker.service")
        bundle = "${dev.dockerCompose.bundle}"
        compose = """${compose}"""

        def inspect(service):
            container, = machine.succeed(f"{compose} ps --all --quiet {service}").split()
            return json.loads(machine.succeed(f"${docker} inspect {container}"))[0]

        def url():
            address = machine.succeed(f"{compose} port guestbook 8080").splitlines()[0]
            return "http://127.0.0.1:" + address.rsplit(":", 1)[1]

        def ready():
            settle([url()])

        with subtest("the project renders the stateful settings"):
            report = json.loads(r"""${json dev.dockerCompose.capabilityReport}""")
            assert report["canRender"]
            warnings = {(d["code"], d["field"]) for d in report["diagnostics"] if d["severity"] == "warning"}
            for warning in (
                ("UnsupportedComposeNetworkProbe", "services.guestbook.probes.readiness.type"),
                ("UnsupportedComposeNetworkProbe", "services.guestbook.probes.liveness.type"),
                ("UnsupportedComposeInitialization", "services.guestbook.initialization.steps"),
            ):
                assert warning in warnings, warnings
            manifest = json.loads(machine.succeed(f"cat {bundle}/manifests/guestbook.json"))
            probes = manifest["probes"]
            assert (probes["readiness"]["type"], probes["readiness"]["path"], probes["readiness"]["port"]) == ("http", "/readyz", "http")
            assert (probes["liveness"]["type"], probes["liveness"]["path"], probes["liveness"]["port"]) == ("http", "/healthz", "http")
            step, = manifest["initialization"]["steps"]
            assert step["id"] == "migrate" and step["argv"] == ["migrate"]

            config = json.loads(machine.succeed(f"{compose} config --format json"))
            app, db = config["services"]["guestbook"], config["services"]["postgres"]
            assert app["depends_on"]["postgres"]["condition"] == "service_healthy"
            assert "healthcheck" not in app
            assert db["healthcheck"]["test"][1].endswith("/bin/pg_isready")
            assert app["ports"][0]["target"] == 8080 and "ports" not in db
            assert set(db["networks"]) == {"billet-internal"}
            assert set(app["networks"]) == {"billet-internal", "billet-egress"}
            assert (app["stop_signal"], app["restart"], db["stop_signal"]) == ("SIGTERM", "on-failure:3", "SIGINT")
            assert app["environment"]["GUESTBOOK_DATABASE_PASSWORD"] == password
            assert [secret["target"] for secret in app["secrets"]] == ["/run/secrets/guestbook/session-key"]
            assert [secret["target"] for secret in db["secrets"]] == ["/run/secrets/postgres/password"]
            volume, = db["volumes"]
            assert (volume["type"], volume["target"]) == ("volume", "/var/lib/postgresql")

        with subtest("readiness waits for the migration"):
            for name in ("guestbook", "postgres"):
                machine.succeed(f"${docker} image load --input {bundle}/images/{name}.tar")
            status, output = machine.execute(f"{compose} up --no-build --detach 2>&1")
            if status:
                machine.execute(f"{compose} logs >&2")
            assert status == 0, output
            assert inspect("postgres")["State"]["Health"]["Status"] == "healthy"
            machine.wait_until_succeeds(f"curl -fsS {url()}/healthz", timeout=60)
            status, body = request(f"{url()}/readyz")
            assert status == 503 and not body["ready"], body
            # Compose does not map initialization; the fixture runs the
            # manifest's step the way a consumer would before each start.
            migrate = f"{compose} run --rm --no-deps --entrypoint {step['executable']} guestbook {shlex.join(step['argv'])} 2>&1"
            assert "applied migration 1" in machine.succeed(migrate)
            assert "schema already at version 1" in machine.succeed(migrate)
            ready()
            assert request(f"{url()}/readyz") == (200, {"ready": True, "schema": 1})

        with subtest("secrets arrive at their declared targets"):
            app = inspect("guestbook")
            assert f"GUESTBOOK_DATABASE_PASSWORD={password}" in app["Config"]["Env"]
            copied = machine.succeed(f"${docker} cp {app['Id']}:/run/secrets/guestbook/session-key - | tar -xOf -")
            assert copied == key
            db = inspect("postgres")
            assert machine.succeed(f"${docker} cp {db['Id']}:/run/secrets/postgres/password - | tar -xOf -") == password
            status, created = request(f"{url()}/entries", {"author": "ada", "message": "hello from compose"})
            assert status == 201, created
            assert created["signature"] == signed(key, {"id": created["id"], "author": "ada", "message": "hello from compose"})

        with subtest("malformed and oversized bodies are rejected"):
            assert request(f"{url()}/entries", {"author": "ada"})[0] == 400
            # Only headers are sent; the server answers without reading a body.
            for length, expected in (("70000", "413"), ("-1", "400"), ("many", "411")):
                status = machine.succeed(f"curl -sS -o /dev/null -w '%{{http_code}}' -X POST -H 'Content-Length: {length}' {url()}/entries")
                assert status == expected, (length, status)

        with subtest("entries survive restarts"):
            expected = [("ada", "hello from compose")]
            for service in ("guestbook", "postgres"):
                machine.succeed(f"{compose} restart {service}")
                ready()
                assert entries(url(), key) == expected
            machine.succeed(f"{compose} down")
            machine.succeed("${docker} volume inspect guestbook_postgres__data")
            machine.succeed(f"{compose} up --no-build --detach")
            ready()
            assert entries(url(), key) == expected

        with subtest("the database leaves its volume root unchanged"):
            stat = f"${docker} exec {inspect('postgres')['Id']} ${pkgs.coreutils}/bin/stat -c '%u:%g %a'"
            assert machine.succeed(f"{stat} /var/lib/postgresql").startswith("0:0 ")
            assert machine.succeed(f"{stat} /var/lib/postgresql/pg").strip().startswith("65534:65534 ")
            assert machine.succeed(f"{stat} /var/lib/postgresql/pg/data").strip() == "65534:65534 700"

        with subtest("services stop on their declared signals"):
            app, db = inspect("guestbook"), inspect("postgres")
            assert (app["Config"]["StopSignal"], app["Config"]["StopTimeout"]) == ("SIGTERM", 15)
            assert (db["Config"]["StopSignal"], db["Config"]["StopTimeout"]) == ("SIGINT", 60)
            assert app["HostConfig"]["RestartPolicy"] == {"Name": "on-failure", "MaximumRetryCount": 3}
            machine.succeed(f"{compose} stop guestbook postgres")
            assert inspect("guestbook")["State"]["ExitCode"] == 0
            assert inspect("postgres")["State"]["ExitCode"] == 0
            logs = machine.succeed(f"{compose} logs guestbook postgres 2>&1")
            assert "received SIGTERM; shutting down" in logs
            assert "received fast shutdown request" in logs
            machine.succeed(f"{compose} down --volumes")
            assert machine.succeed("${docker} ps -aq").strip() == ""
      '';
    };

    "billet:guestbook-kubernetes" = let
      bundle = prod.kubernetes.bundle;
    in
      pkgs.testers.runNixOSTest {
        name = "billet-guestbook-kubernetes";
        globalTimeout = 1200;
        passthru.bloomery = [
          "BILLET-PUBLIC-EXAMPLES-013"
          "BILLET-PUBLIC-EXAMPLES-014"
          "BILLET-PUBLIC-EXAMPLES-015"
          "BILLET-PUBLIC-EXAMPLES-016"
          "BILLET-PUBLIC-EXAMPLES-017"
          "BILLET-PUBLIC-EXAMPLES-018"
          "BILLET-PUBLIC-EXAMPLES-019"
          "BILLET-PUBLIC-EXAMPLES-021"
        ];
        nodes.machine = {config, ...}: {
          virtualisation = {
            memorySize = 4096;
            cores = 2;
            diskSize = 8192;
          };
          networking.firewall.enable = false;
          # The local-path provisioner supplies the database claim.
          services.k3s = {
            enable = true;
            disable = ["traefik" "servicelb" "metrics-server"];
            images = [config.services.k3s.package.airgap-images];
          };
          environment.systemPackages = [pkgs.curl];
        };
        testScript = ''
          ${common}
          machine.wait_for_unit("k3s.service")
          machine.wait_until_succeeds("k3s kubectl get --raw=/readyz")
          machine.wait_until_succeeds("k3s kubectl wait --for=condition=Ready node --all --timeout=10s", timeout=180)
          ${lib.concatMapStringsSep "\n" (name: ''
              machine.succeed("cmp ${prod.billets.${name}.manifest} ${bundle}/manifests/${name}.json")
              machine.succeed("k3s ctr images import ${bundle}/images/${name}.tar")
            '')
            members}
          machine.succeed("k3s kubectl -n kube-system rollout status deployment/coredns --timeout=120s")
          kubectl = "k3s kubectl -n guestbook"
          selector = "-l billet.actionable.work/application"

          with subtest("the manifests render probes, initialization, secrets and rollout"):
              items = json.loads(machine.succeed("cat ${bundle}/kubernetes.json"))["items"]
              resource = lambda kind, name: next(i for i in items if i["kind"] == kind and i["metadata"]["name"] == name)
              app = resource("Deployment", "guestbook")["spec"]
              pod = app["template"]["spec"]
              container, = pod["containers"]
              assert app["replicas"] == 2
              assert app["strategy"] == {"type": "RollingUpdate", "rollingUpdate": {"maxSurge": 1, "maxUnavailable": 0}}
              assert (app["minReadySeconds"], app["progressDeadlineSeconds"], pod["terminationGracePeriodSeconds"]) == (10, 180, 30)
              assert container["readinessProbe"] == {
                  "httpGet": {"path": "/readyz", "port": 8080}, "periodSeconds": 5, "timeoutSeconds": 2, "failureThreshold": 3,
              }
              assert container["livenessProbe"] == {
                  "httpGet": {"path": "/healthz", "port": 8080}, "periodSeconds": 10, "timeoutSeconds": 2, "failureThreshold": 3,
              }
              init, = pod["initContainers"]
              assert init["command"][0].endswith("/bin/guestbook") and init["args"] == ["migrate"]
              env = {item["name"]: item for item in container["env"]}
              assert env["GUESTBOOK_DATABASE_PASSWORD"]["valueFrom"]["secretKeyRef"] == {
                  "name": "guestbook", "key": "database-password", "optional": False,
              }
              assert "/run/secrets/guestbook/session-key" in {m["mountPath"] for m in container["volumeMounts"]}
              db = resource("Deployment", "postgres")["spec"]
              assert db["strategy"] == {"type": "Recreate"}
              assert db["template"]["spec"]["terminationGracePeriodSeconds"] == 60
              assert db["template"]["spec"]["containers"][0]["readinessProbe"]["exec"]["command"][0].endswith("/bin/pg_isready")
              claim, = (i for i in items if i["kind"] == "PersistentVolumeClaim")
              assert claim["spec"]["storageClassName"] == "local-path"
              assert claim["spec"]["accessModes"] == ["ReadWriteOnce"]
              policy = resource("NetworkPolicy", "postgres")["spec"]
              assert policy["policyTypes"] == ["Ingress", "Egress"] and policy["egress"] == []
              assert policy["ingress"] == [{
                  "from": [{"podSelector": {"matchLabels": {"billet.actionable.work/application": "guestbook"}}}],
                  "ports": [{"port": 5432, "protocol": "TCP"}],
              }]

          with subtest("both replicas become ready after the migration"):
              machine.succeed("k3s kubectl create namespace guestbook")
              machine.succeed(f"{kubectl} create secret generic guestbook --from-file=database-password=/tmp/db-password --from-file=session-key=/tmp/session-key")
              machine.succeed(f"{kubectl} apply --server-side --validate=strict -f ${bundle}/kubernetes.json")
              for name in ("postgres", "guestbook"):
                  status, output = machine.execute(f"{kubectl} rollout status deployment/{name} --timeout=420s", timeout=480)
                  if status:
                      machine.execute(f"{kubectl} describe pods >&2")
                      machine.execute(f"{kubectl} logs {selector}={name} --all-containers=true >&2")
                  assert status == 0, output

              def pods():
                  items = json.loads(machine.succeed(f"{kubectl} get pods {selector}=guestbook -o json"))["items"]
                  return [p for p in items if p["status"]["phase"] == "Running" and "deletionTimestamp" not in p["metadata"]]

              def migrations():
                  return sorted(machine.succeed(f"{kubectl} logs {p['metadata']['name']} -c init-0") for p in pods())

              # Address each replica directly rather than through the Service.
              def replicas():
                  current = pods()
                  assert len(current) == 2, [p["metadata"]["name"] for p in current]
                  return [f"http://{p['status']['podIP']}:8080" for p in current]

              outcomes = migrations()
              assert len(outcomes) == 2, outcomes
              assert sum("applied migration 1" in log for log in outcomes) == 1, outcomes
              assert sum("schema already at version 1" in log for log in outcomes) == 1, outcomes
              url = "http://" + machine.succeed(f"{kubectl} get service guestbook -o jsonpath='{{.spec.clusterIP}}'") + ":8080"
              settle(replicas())
              for replica in replicas():
                  assert request(f"{replica}/readyz") == (200, {"ready": True, "schema": 1})

          with subtest("secrets arrive through the Kubernetes Secret"):
              status, created = request(f"{url}/entries", {"author": "grace", "message": "hello from k3s"})
              assert status == 201, created
              assert created["signature"] == signed(key, {"id": created["id"], "author": "grace", "message": "hello from k3s"})

          with subtest("entries survive pod replacement"):
              expected = [("grace", "hello from k3s")]
              machine.succeed(f"{kubectl} delete pod {selector}=postgres --wait=true --timeout=120s")
              machine.succeed(f"{kubectl} rollout status deployment/postgres --timeout=300s")
              settle(replicas())
              assert all(entries(replica, key) == expected for replica in replicas())
              machine.succeed(f"{kubectl} rollout restart deployment/guestbook")
              machine.succeed(f"{kubectl} rollout status deployment/guestbook --timeout=300s")
              settle(replicas())
              assert all(entries(replica, key) == expected for replica in replicas())
              assert all("schema already at version 1" in log for log in migrations())
              owners = machine.succeed(f"{kubectl} exec deployment/postgres -- ${pkgs.coreutils}/bin/stat -c %u:%g /var/lib/postgresql /var/lib/postgresql/pg")
              assert owners.split() == ["0:0", "65534:65534"], owners
        '';
      };
  }
