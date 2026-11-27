{
  pkgs,
  billetLib,
  checkers,
}: let
  inherit (pkgs) lib;
  fixtures = import ./fixtures.nix {inherit pkgs billetLib;};
  ingressRate = 300000000;
  egressRate = 180000000;
  service = name: extra:
    fixtures.evaluate (lib.recursiveUpdate fixtures.base (lib.recursiveUpdate {
        identity.name = name;
        process = {
          package = pkgs.iperf3;
          executable = "bin/iperf3";
          argv = ["--server"];
        };
        network.ports.iperf = {
          port = 5201;
          exposure = "public";
        };
        storage.scratch = {
          mountPoint = "/tmp";
          medium = "memory";
          sizeBytes = 8 * 1024 * 1024;
          driverClass = "tmpfs";
        };
        resources.cpuLimit = 2000;
      }
      extra));
  baseline = service "baseline" {};
  capped = service "capped" {
    kubernetes.bandwidthProfile = "pod-annotations";
    network.bandwidth = {
      ingress.maxBitsPerSecond = ingressRate;
      egress.maxBitsPerSecond = egressRate;
    };
  };
  peer = name: nodeName: {
    apiVersion = "v1";
    kind = "Pod";
    metadata = {inherit name;};
    spec = {
      inherit nodeName;
      volumes = [
        {
          name = "scratch";
          emptyDir.medium = "Memory";
        }
      ];
      containers = [
        {
          name = "iperf";
          image = baseline.ociImage.imageRefUnsafe;
          imagePullPolicy = "Never";
          volumeMounts = [
            {
              name = "scratch";
              mountPath = "/tmp";
            }
          ];
        }
      ];
    };
  };
  peers = pkgs.writeText "bandwidth-peers.json" (builtins.toJSON {
    apiVersion = "v1";
    kind = "List";
    items = [(peer "same-peer" "server") (peer "cross-peer" "worker")];
  });
  flannel = pkgs.writeText "bandwidth-flannel.conflist" (builtins.toJSON {
    name = "cbr0";
    cniVersion = "1.0.0";
    plugins = [
      {
        type = "flannel";
        delegate = {
          hairpinMode = true;
          forceAddress = true;
          isDefaultGateway = true;
        };
      }
      {
        type = "portmap";
        capabilities.portMappings = true;
      }
      {
        type = "bandwidth";
        capabilities.bandwidth = true;
      }
    ];
  });
  parameters = pkgs.writeText "kubernetes-bandwidth.json" (builtins.toJSON {
    inherit ingressRate egressRate;
    iperf3 = "${pkgs.iperf3}";
    baselineFile = "${baseline.kubernetes.file}";
    cappedFile = "${capped.kubernetes.file}";
    peers = "${peers}";
  });
  clusterNode = {config, ...}: let
    interface = builtins.head (builtins.filter (iface: iface.assignIP) (builtins.attrValues config.virtualisation.allInterfaces));
  in {
    virtualisation = {
      memorySize = 4096;
      cores = 3;
      diskSize = 8192;
    };
    networking.firewall.enable = false;
    boot.kernelModules = ["ifb" "sch_tbf" "act_mirred" "cls_u32"];
    services.k3s = {
      enable = true;
      token = "billet-bandwidth-test";
      extraFlags = ["--node-ip=${config.networking.primaryIPAddress}" "--flannel-iface=${interface.name}" "--flannel-cni-conf=${flannel}"];
      images = [config.services.k3s.package.airgap-images baseline.dockerImage];
    };
  };
in {
  "billet:kubernetes-bandwidth-live" = pkgs.testers.runNixOSTest {
    name = "billet-kubernetes-bandwidth-live";
    passthru.bloomery = [
      "BILLET-IR-BANDWIDTH-029"
      "BILLET-IR-BANDWIDTH-030"
      "BILLET-IR-BANDWIDTH-031"
      "BILLET-IR-BANDWIDTH-032"
      "BILLET-IR-BANDWIDTH-033"
      "BILLET-IR-BANDWIDTH-034"
    ];
    nodes.server = {
      imports = [clusterNode];
      services.k3s = {
        disable = ["traefik" "servicelb" "local-storage" "metrics-server"];
        images = [capped.dockerImage];
      };
    };
    nodes.worker = {nodes, ...}: {
      imports = [clusterNode];
      services.k3s = {
        role = "agent";
        serverAddr = "https://${nodes.server.networking.primaryIPAddress}:6443";
        extraFlags = ["--node-taint=bandwidth-test=peer:NoSchedule"];
      };
    };
    nodes.external = {
      virtualisation.memorySize = 512;
      networking.firewall.enable = false;
      environment.systemPackages = [pkgs.iperf3];
    };
    testScript = {nodes, ...}: ''
      check = "${checkers.kubernetes}/bin/billet-vm-kubernetes"
      start_all()
      server.wait_for_unit("k3s.service")
      cidr, baseline, capped = server.succeed(f"{check} kubernetes-bandwidth-setup ${parameters}", timeout=900).split()
      external.succeed(f"{check} kubernetes-bandwidth-route {cidr} ${nodes.server.networking.primaryIPAddress}")
      for route, machine in [("same-node", server), ("cross-node", server), ("external", external)]:
          for direction in ["ingress", "egress"]:
              with subtest(f"{route} {direction} aggregate maximum"):
                  machine.succeed(f"{check} kubernetes-bandwidth-measure ${parameters} {route} {direction} {baseline} {capped} >&2", timeout=600)
    '';
  };
}
