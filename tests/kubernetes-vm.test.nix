{
  pkgs,
  billetLib,
  checkers,
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
  parameters = pkgs.writeText "kubernetes-k3s.json" (builtins.toJSON {
    inherit bundle core busybox tokenFile;
    curl = lib.getExe pkgs.curl;
    fixtureManifest = "${fixture.manifest}";
    kubernetesFile = "${fixture.kubernetes.file}";
    dockerImage = "${fixture.dockerImage}";
    imageRef = fixture.ociImage.imageRefUnsafe;
    peerImage = "${peer.dockerImage}";
    peerFile = "${peer.kubernetes.file}";
    upgradeV1Image = "${upgradeV1.dockerImage}";
    upgradeV2Image = "${upgradeV2.dockerImage}";
    upgradeV1File = "${upgradeV1.kubernetes.file}";
    upgradeV2File = "${upgradeV2.kubernetes.file}";
    upgradeV1Ref = upgradeV1.ociImage.imageRefUnsafe;
    upgradeV2Ref = upgradeV2.ociImage.imageRefUnsafe;
  });
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
      machine.start()
      machine.wait_for_unit("k3s.service")
      machine.succeed("${checkers.kubernetes}/bin/billet-vm-kubernetes kubernetes-k3s ${parameters} >&2", timeout=1500)
    '';
  };
}
