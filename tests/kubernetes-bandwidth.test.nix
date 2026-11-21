{
  pkgs,
  billetLib,
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
      from datetime import timedelta
      import ipaddress
      import json
      import math

      kubectl = "k3s kubectl -n default"
      start_all()
      server.wait_for_unit("k3s.service")
      server.wait_until_succeeds(f"{kubectl} wait --for=condition=Ready node/server node/worker --timeout=10s", timeout=timedelta(minutes=3))
      server.succeed(f"{kubectl} apply --server-side --validate=strict -f ${baseline.kubernetes.file} -f ${capped.kubernetes.file} -f ${peers}")
      server.succeed(f"{kubectl} rollout status deployment/baseline --timeout=120s")
      server.succeed(f"{kubectl} rollout status deployment/capped --timeout=120s")
      server.succeed(f"{kubectl} wait --for=condition=Ready pod/same-peer pod/cross-peer --timeout=120s")

      targets = {}
      for workload in ["baseline", "capped"]:
          pods = json.loads(server.succeed(f"{kubectl} get pod -l billet.actionable.work/application={workload} -o json"))
          [pod] = pods["items"]
          assert pod["spec"]["nodeName"] == "server", pod["spec"]["nodeName"]
          targets[workload] = str(ipaddress.IPv4Address(pod["status"]["podIP"]))
      for peer, node in [("same-peer", "server"), ("cross-peer", "worker")]:
          assert server.succeed(f"{kubectl} get pod {peer} -o jsonpath='{{.spec.nodeName}}'") == node
      pod_cidr = ipaddress.IPv4Network(server.succeed(f"{kubectl} get node server -o jsonpath='{{.spec.podCIDR}}'"))
      external.succeed(f"ip route add {pod_cidr} via ${nodes.server.networking.primaryIPAddress}")

      def through(machine, command, workload, reverse, warmup, duration):
          direction = "--reverse" if reverse else ""
          result = json.loads(machine.succeed(
              f"{command} --client {targets[workload]} --parallel 3 --json "
              f"--omit {warmup} --time {duration} {direction}", timeout=timedelta(minutes=2)
          ))
          streams = result["end"]["streams"]
          assert len(streams) == 3 and all(stream["receiver"]["bytes"] > 0 for stream in streams), result
          return result["end"]["sum_received"]["bits_per_second"]

      for route, machine, command in [
          ("same-node", server, f"{kubectl} exec same-peer -- ${pkgs.iperf3}/bin/iperf3"),
          ("cross-node", server, f"{kubectl} exec cross-peer -- ${pkgs.iperf3}/bin/iperf3"),
          ("external", external, "iperf3"),
      ]:
          for direction, reverse, limit in [("ingress", False, ${toString ingressRate}), ("egress", True, ${toString egressRate})]:
              with subtest(f"{route} {direction} aggregate maximum"):
                  uncapped = through(machine, command, "baseline", reverse, 1, 3)
                  assert uncapped > limit * 1.5, f"baseline {uncapped:.0f} cannot distinguish limit {limit}"
                  # containerd supplies up to 2^32-1 initial burst bits. Allow twice
                  # the estimated drain time so the measurement covers sustained traffic.
                  warmup = max(3, math.ceil(2 * (2**32 - 1) / (uncapped - limit)))
                  measured = through(machine, command, "capped", reverse, warmup, 6)
                  print(f"{route} {direction}: uncapped={uncapped:.0f}, capped={measured:.0f}, limit={limit}")
                  assert 0.75 * limit <= measured <= 1.12 * limit, (
                      f"uncapped={uncapped:.0f}, capped={measured:.0f}, limit={limit}, warmup={warmup}"
                  )
    '';
  };
}
