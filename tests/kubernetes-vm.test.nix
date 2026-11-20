{
  pkgs,
  billetLib,
}: let
  inherit (pkgs) lib;
  core = "${pkgs.coreutils}/bin";
  busybox = "${pkgs.busybox}/bin/busybox";
  tokenDirectory = "/var/run/secrets/kubernetes.io/serviceaccount";
  tokenFile = "${tokenDirectory}/app-key";
  apiEnv = "literal-$(KUBERNETES_SERVICE_PORT)-$$";
  privateLink = {
    sourceService = "kube-peer";
    destinationService = "kube-app";
    destinationPort = "metrics";
  };
  app = pkgs.writeShellScriptBin "kubernetes-app" ''
    set -eu
    test "$#" -eq 3
    test -z "$1"
    test "$2" = '$(TOKEN)'
    test "$3" = 'a; b'
    test "$PWD" = /working
    test "$MARKER" = from-image
    test "$KUBERNETES_SERVICE_HOST" = '${apiEnv}'
    test "$("${core}/id" -u):$("${core}/id" -g)" = 1001:1002
    test "${"$"}{OPTIONAL+x}" = ""
    test -n "$TOKEN"
    test "$KUBERNETES_SERVICE_PORT" = "$TOKEN"
    test "$("${core}/cat" "${tokenFile}")" = "$TOKEN"
    test ! -e "${tokenDirectory}/token"
    test "$("${core}/cat" /scratch/init)" = '$(TOKEN):second'
    printf '%s\n' "ready" >/scratch/index.html
    ${busybox} httpd -p 9090 -h /scratch
    exec ${busybox} httpd -f -p 8080 -h /scratch
  '';
  init = pkgs.writeShellScriptBin "kubernetes-init" ''
    set -eu
    test "$MARKER" = from-image
    test "$KUBERNETES_SERVICE_HOST" = '${apiEnv}'
    test "$PWD" = /working
    if test "$#" = 1; then
      printf '%s' "$1" >/scratch/init
    else
      printf ':second' >>/scratch/init
    fi
  '';
  ready = pkgs.writeShellScriptBin "kubernetes-ready" ''
    test "$#" = 2 && test -z "$1" && test "$2" = '$(TOKEN)' && test -f /scratch/index.html
  '';
  fixture = billetLib.mkBillet {
    inherit pkgs;
    modules = [
      ../examples/hello/application.nix
      {
        identity.name = lib.mkForce "kube-app";
        oci.imageName = "docker.io/library/kube-app";
        process = {
          package = lib.mkForce app;
          executable = lib.mkForce "bin/kubernetes-app";
          argv = lib.mkForce ["" "$(TOKEN)" "a; b"];
          workingDirectory = "/working";
          user = "1001:1002";
          environment = {
            MARKER = "from-image";
            KUBERNETES_SERVICE_HOST = apiEnv;
          };
        };
        kubernetes = {
          namespace = "billet-test";
          createNamespace = true;
        };
        resources.memoryLimit = lib.mkForce 134217728;
        initialization = {
          budgetSeconds = 4;
          steps = map (step:
            step
            // {
              package = init;
              executable = "bin/kubernetes-init";
              timeoutSeconds = 2;
            }) [
            {
              id = "first";
              argv = ["$(TOKEN)"];
            }
            {
              id = "second";
              argv = [];
            }
          ];
        };
        probes = {
          startup = {
            type = "tcp";
            port = "web";
            intervalSeconds = 1;
          };
          readiness = {
            command = {
              package = ready;
              executable = "bin/kubernetes-ready";
              argv = ["" "$(TOKEN)"];
            };
            intervalSeconds = 1;
          };
          liveness = {
            type = "http";
            port = "web";
            path = "/index.html";
            intervalSeconds = 1;
          };
        };
        rollout.minReadySeconds = 0;
        shutdown.stopGracePeriodSeconds = 7;
        network.ports = {
          web = {
            port = 8080;
            protocol = "http";
            exposure = "public";
          };
          metrics.port = 9090;
        };
        network.privateConnections = [privateLink];
        secrets = {
          file = {
            external = "runtime/token";
            target = tokenFile;
          };
          token = {
            external = "runtime/token";
            target = "TOKEN";
            mode = "environment";
          };
          apiPort = {
            external = "runtime/token";
            target = "KUBERNETES_SERVICE_PORT";
            mode = "environment";
          };
          optional = {
            external = "runtime/absent";
            target = "OPTIONAL";
            mode = "environment";
            required = false;
          };
        };
        storage.scratch = {
          medium = "memory";
          mountPoint = "/scratch";
          sizeBytes = 4194304;
          driverClass = "tmpfs";
        };
      }
    ];
  };
  peerPackage = pkgs.writeShellScriptBin "kubernetes-peer" ''
    ${busybox} true
    exec ${core}/sleep infinity
  '';
  peer = billetLib.mkBillet {
    inherit pkgs;
    modules = [
      ../examples/hello/application.nix
      {
        identity.name = lib.mkForce privateLink.sourceService;
        oci.imageName = "docker.io/library/kube-peer";
        kubernetes.namespace = "billet-test";
        process = {
          package = lib.mkForce peerPackage;
          executable = lib.mkForce "bin/kubernetes-peer";
          argv = lib.mkForce [];
        };
        rollout.minReadySeconds = 0;
        network = {
          publicEgress = false;
          privateConnections = [privateLink];
        };
      }
    ];
  };
  upgradeApp = pkgs.writeShellScriptBin "upgrade-app" ''
    echo "BILLET_UPGRADE $1"
    exec ${core}/sleep infinity
  '';
  # Two versions of one Billet that differ in version, argv and image tag.
  upgrade = version: argument:
    billetLib.mkBillet {
      inherit pkgs;
      modules = [
        ../examples/hello/application.nix
        {
          identity = {
            name = lib.mkForce "kube-upgrade";
            version = lib.mkForce version;
          };
          oci.imageName = "docker.io/library/kube-upgrade";
          process = {
            package = lib.mkForce upgradeApp;
            executable = lib.mkForce "bin/upgrade-app";
            argv = lib.mkForce [argument];
          };
          kubernetes = {
            namespace = "billet-upgrade";
            createNamespace = true;
          };
          rollout = {
            maxSurge = 1;
            maxUnavailable = 0;
            minReadySeconds = 2;
            progressDeadlineSeconds = 120;
          };
          shutdown.stopGracePeriodSeconds = 3;
        }
      ];
    };
  upgradeV1 = upgrade "1.0.0" "v1";
  upgradeV2 = upgrade "2.0.0" "v2";
  inherit (fixture.kubernetes) bundle;
in {
  "billet:kubernetes-k3s" = pkgs.testers.runNixOSTest {
    name = "billet-kubernetes-k3s";
    passthru.bloomery = [
      "BILLET-IR-KUBERNETES-004"
      "BILLET-IR-KUBERNETES-005"
      "BILLET-IR-KUBERNETES-007"
      "BILLET-IR-KUBERNETES-055"
      "BILLET-IR-KUBERNETES-056"
      "BILLET-IR-KUBERNETES-057"
      "BILLET-IR-KUBERNETES-058"
      "BILLET-IR-KUBERNETES-059"
      "BILLET-IR-KUBERNETES-060"
      "BILLET-IR-KUBERNETES-061"
      "BILLET-IR-KUBERNETES-062"
      "BILLET-IR-KUBERNETES-063"
      "BILLET-IR-KUBERNETES-074"
      "BILLET-IR-KUBERNETES-075"
      "BILLET-IR-KUBERNETES-078"
      "BILLET-IR-KUBERNETES-081"
      "BILLET-IR-KUBERNETES-084"
      "BILLET-IR-KUBERNETES-090"
      "BILLET-IR-KUBERNETES-091"
      "BILLET-IR-KUBERNETES-092"
      "BILLET-IR-KUBERNETES-112"
      "BILLET-IR-KUBERNETES-113"
      "BILLET-IR-KUBERNETES-114"
    ];
    nodes.machine = {config, ...}: {
      virtualisation = {
        memorySize = 4096;
        cores = 2;
        diskSize = 8192;
      };
      networking.firewall.enable = false;
      services.k3s = {
        enable = true;
        disable = ["traefik" "servicelb" "local-storage" "metrics-server"];
        images = [config.services.k3s.package.airgap-images];
      };
    };
    testScript = ''
      import json

      kubectl = "k3s kubectl -n billet-test"
      machine.start()
      machine.wait_for_unit("k3s.service")
      machine.wait_until_succeeds("k3s kubectl get --raw=/readyz")
      machine.wait_until_succeeds("k3s kubectl wait --for=condition=Ready node --all --timeout=10s", timeout=180)
      assert machine.succeed("k3s kubectl get namespace billet-test --ignore-not-found -o name") == ""

      machine.succeed("cmp ${fixture.manifest} ${bundle}/manifest.json")
      machine.succeed("cmp ${fixture.kubernetes.file} ${bundle}/kubernetes.json")
      machine.succeed("cmp ${fixture.dockerImage} ${bundle}/image.tar")
      machine.succeed("k3s ctr images import ${bundle}/image.tar")
      machine.succeed("k3s kubectl apply --server-side --validate=strict -f ${bundle}/kubernetes.json")
      assert machine.succeed("k3s kubectl get namespace billet-test -o jsonpath='{.status.phase}'") == "Active"
      machine.succeed("k3s kubectl apply --server-side --dry-run=server --validate=strict -f ${bundle}/kubernetes.json")
      machine.succeed("printf '%s' \"$(cat /proc/sys/kernel/random/uuid)\" >/tmp/billet-token")
      machine.succeed(f"{kubectl} create secret generic runtime --from-file=token=/tmp/billet-token")
      status, rollout = machine.execute(f"{kubectl} rollout status deployment/kube-app --timeout=90s")
      if status != 0:
          machine.execute(f"{kubectl} describe pods")
          machine.execute(f"{kubectl} logs deployment/kube-app --all-containers=true")
      assert status == 0, rollout

      pods = json.loads(machine.succeed(f"{kubectl} get pods -o json"))["items"]
      assert len(pods) == 1
      pod = pods[0]
      assert [status["state"]["terminated"]["exitCode"]
              for status in pod["status"]["initContainerStatuses"]] == [0, 0]
      container = pod["status"]["containerStatuses"][0]
      assert container["ready"] and container["started"]
      assert container["image"] == "${fixture.ociImage.imageRefUnsafe}"
      assert pod["spec"]["containers"][0]["startupProbe"]["tcpSocket"]["port"] == 8080
      assert pod["spec"]["terminationGracePeriodSeconds"] == 7
      service_ip = machine.succeed(f"{kubectl} get service kube-app -o jsonpath='{{.spec.clusterIP}}'").strip()
      service_request = f"${lib.getExe pkgs.curl} --fail --silent --show-error --max-time 2 http://{service_ip}:8080/index.html"
      assert machine.wait_until_succeeds(service_request, timeout=60) == "ready\n"
      mount_info = machine.succeed(f"{kubectl} exec deployment/kube-app -- ${core}/cat /proc/mounts")
      scratch = next(line.split() for line in mount_info.splitlines() if line.split()[1] == "/scratch")
      assert scratch[2] == "tmpfs" and "size=4096k" in scratch[3].split(",")
      secret = next(line.split() for line in mount_info.splitlines() if line.split()[1] == "${tokenFile}")
      assert pod["spec"]["automountServiceAccountToken"] is False and "ro" in secret[3].split(",")

      peer_args = "--image=${fixture.ociImage.imageRefUnsafe} --image-pull-policy=Never"
      machine.succeed("k3s ctr images import ${peer.dockerImage}")
      machine.succeed("k3s kubectl apply --server-side --validate=strict -f ${peer.kubernetes.file}")
      machine.succeed(f"{kubectl} run denied {peer_args} --command -- ${core}/sleep infinity")
      machine.succeed(f"{kubectl} rollout status deployment/kube-peer --timeout=90s")
      machine.succeed(f"{kubectl} wait --for=condition=Ready pod/denied --timeout=60s")

      def request(port):
          return f"${busybox} wget -T 2 -qO- http://{service_ip}:{port}/index.html"

      def wait_for_denial(peer_name, port):
          denial = "'\"$@\"; test \"$?\" -eq 1'"
          machine.wait_until_succeeds(f"{kubectl} exec {peer_name} -- ${busybox} sh -c {denial} sh {request(port)}", timeout=30)

      assert machine.wait_until_succeeds(f"{kubectl} exec deployment/kube-peer -- {request(9090)}", timeout=60) == "ready\n"
      assert machine.wait_until_succeeds(f"{kubectl} exec denied -- {request(8080)}", timeout=60) == "ready\n"
      wait_for_denial("denied", 9090)
      wait_for_denial("deployment/kube-peer", 8080)

      with subtest("the consumer accepts a second Billet version"):
          import time

          upgrade = "k3s kubectl -n billet-upgrade"
          machine.succeed("k3s ctr images import ${upgradeV1.dockerImage}")
          machine.succeed("k3s ctr images import ${upgradeV2.dockerImage}")
          machine.succeed("k3s kubectl apply --server-side --validate=strict -f ${upgradeV1.kubernetes.file}")
          machine.succeed(f"{upgrade} rollout status deployment/kube-upgrade --timeout=90s")
          first = json.loads(machine.succeed(f"{upgrade} get deployment kube-upgrade -o json"))
          machine.succeed("k3s kubectl apply --server-side --validate=strict -f ${upgradeV2.kubernetes.file}")
          machine.succeed(f"{upgrade} rollout status deployment/kube-upgrade --timeout=120s")

          deployment = json.loads(machine.succeed(f"{upgrade} get deployment kube-upgrade -o json"))
          spec = deployment["spec"]
          assert deployment["metadata"]["generation"] > first["metadata"]["generation"]
          assert spec["strategy"] == {"type": "RollingUpdate", "rollingUpdate": {"maxSurge": 1, "maxUnavailable": 0}}, spec["strategy"]
          assert (spec["minReadySeconds"], spec["progressDeadlineSeconds"]) == (2, 120)
          annotations = spec["template"]["metadata"]["annotations"]
          assert annotations["billet.actionable.work/identity-version"] == "2.0.0"
          assert first["spec"]["template"]["metadata"]["annotations"]["billet.actionable.work/identity-version"] == "1.0.0"

          def second_version_pods():
              pods = json.loads(machine.succeed(f"{upgrade} get pods -o json"))["items"]
              statuses = [status for pod in pods for status in pod["status"].get("containerStatuses", [])]
              ready = len(pods) == 1 and len(statuses) == 1 and all(
                  status["ready"] and status["image"] == "${upgradeV2.ociImage.imageRefUnsafe}" for status in statuses
              )
              return pods if ready else None

          deadline = time.monotonic() + 60
          while (pods := second_version_pods()) is None:
              assert time.monotonic() < deadline, machine.succeed(f"{upgrade} get pods -o wide")
              time.sleep(1)
          assert "${upgradeV1.ociImage.imageRefUnsafe}" != "${upgradeV2.ociImage.imageRefUnsafe}"
          for pod in pods:
              assert pod["metadata"]["annotations"]["billet.actionable.work/identity-version"] == "2.0.0"
              # The container inherits the second image's argv; its output reports it.
              assert {"command", "args"}.isdisjoint(pod["spec"]["containers"][0])
              assert machine.succeed(f"{upgrade} logs {pod['metadata']['name']}") == "BILLET_UPGRADE v2\n"
    '';
  };
}
