{
  pkgs,
  billetLib,
}: let
  inherit (pkgs) lib;
  inherit (import ./fixtures.nix {inherit pkgs billetLib;}) base evaluate;
  make = name: extra: evaluate (lib.recursiveUpdate base ({identity.name = name;} // extra));
  makeBundle = billets: billetLib.mkBilletBundle {inherit pkgs billets;};
  targets = ["dockerCompose" "kubernetes"];
  has = severity: code: field: report:
    builtins.any (item: item.severity == severity && item.code == code && item.field == field) report.diagnostics;
  refuses = code: field: target:
    !target.capabilityReport.canRender
    && target.capabilityReport.supportedCapabilities == []
    && has "error" code field target.capabilityReport
    && !(builtins.tryEval (builtins.deepSeq target.configuration true)).success
    && !(builtins.tryEval target.file.drvPath).success
    && !(builtins.tryEval target.bundle.drvPath).success;
  renders = target: target.capabilityReport.canRender && builtins.deepSeq target.configuration true;
  peer = make "peer" {};
  bundleFor = client: makeBundle {inherit client peer;};
  protectedPaths = ["/nix" "/nix/store" "/nix/store/closure-entry" "/etc/billet" "/etc/billet/manifest.json" "/etc/billet/closure.json"];
  storage = mountPoint: {
    storage.scratch = {
      inherit mountPoint;
      sizeBytes = 4096;
      medium = "memory";
      driverClass = "tmpfs";
    };
  };
  secret = target: {
    secrets.token = {
      inherit target;
      external = "runtime/token";
    };
  };
  protectedMounts = target: fixture: field:
    builtins.all (path: let
      client = make "client" (fixture path);
      grouped = bundleFor client;
      report = client.${target}.capabilityReport;
    in
      refuses "ProtectedContainerMount" field client.${target}
      && refuses "ProtectedContainerMount" "services.client.${field}" grouped.${target}
      && !lib.hasInfix path (builtins.toJSON report.diagnostics)
      && builtins.isString client.manifest.drvPath
      && builtins.isString client.dockerImage.drvPath)
    protectedPaths;
  unrelated = make "client" (storage "/nix/storehouse" // secret "/etc/billet/token");

  destination = make "destination" {
    network.ports.http = {
      port = 8080;
      protocol = "http";
    };
  };
  link = destinationService: destinationPort: protocol: {
    inherit destinationService destinationPort protocol;
    sourceService = "client";
  };
  links = connections:
    makeBundle {
      inherit destination;
      client = make "client" {network.privateConnections = connections;};
    };
  external = link "external" "http" "grpc";
  matching = link "destination" "http" "http";
  invalidLinks = links [external (link "destination" "http" "grpc") (link "destination" "absent" "http")];
  connectionField = index: field: "services.client.network.privateConnections.${toString index}.${field}";

  graceField = "shutdown.stopGracePeriodSeconds";
  maximumGrace = 9223371916;
  grace = workload: seconds:
    make "client" {
      kubernetes.workload = workload;
      shutdown.stopGracePeriodSeconds = seconds;
    };
  graceTemplate = billet: let
    workload = lib.findFirst (item: item.kind == "Deployment" || item.kind == "Job") null billet.kubernetes.configuration.items;
  in
    workload.spec.template.spec.terminationGracePeriodSeconds;
  qualifiedGrace = workload: seconds: warn: let
    client = grace workload seconds;
    hasWarning = has "warning" "KubernetesMinimumShutdownGrace";
  in
    renders client.kubernetes
    && graceTemplate client == seconds
    && hasWarning graceField client.kubernetes.capabilityReport == warn
    && hasWarning "services.client.${graceField}" (bundleFor client).kubernetes.capabilityReport == warn;
  refusesGrace = workload: let
    client = grace workload (maximumGrace + 1);
  in
    refuses "KubernetesShutdownDuration" graceField client.kubernetes
    && refuses "KubernetesShutdownDuration" "services.client.${graceField}" (bundleFor client).kubernetes
    && client.ir.shutdown.stopGracePeriodSeconds == maximumGrace + 1;

  maximumCpu = 9223371264000;
  cpu = limit: make "client" {resources.cpuLimit = limit;};
  overflowCpu = cpu (maximumCpu + 1);
  cpuMaximum = cpu maximumCpu;
  cpuField = "resources.cpuLimit";
in {
  "billet:protected-container-mounts" = assert protectedMounts "dockerCompose" storage "storage.scratch.mountPoint";
  assert protectedMounts "dockerCompose" secret "secrets.token.target";
  assert protectedMounts "kubernetes" storage "storage.scratch.mountPoint";
  assert protectedMounts "kubernetes" secret "secrets.token.target";
  assert builtins.all (target: renders unrelated.${target} && renders (bundleFor unrelated).${target}) targets;
    pkgs.runCommand "billet-protected-container-mounts" {
      passthru.bloomery = [
        "BILLET-IR-CONSUMER-001"
        "BILLET-IR-CONSUMER-002"
        "BILLET-IR-CONSUMER-003"
        "BILLET-IR-CONSUMER-004"
        "BILLET-IR-CONSUMER-005"
      ];
    } ''touch "$out"'';

  "billet:bundle-destination-ports" = assert builtins.all (target:
    refuses "BundlePrivateConnectionPort" (connectionField 0 "destinationPort") invalidLinks.${target}
    && refuses "BundlePrivateConnectionProtocol" (connectionField 1 "protocol") invalidLinks.${target}
    && renders (links [matching]).${target}
    && renders (links [external]).${target})
  targets;
    pkgs.runCommand "billet-bundle-destination-ports" {
      passthru.bloomery = [
        "BILLET-IR-CONSUMER-006"
        "BILLET-IR-CONSUMER-007"
        "BILLET-IR-CONSUMER-008"
        "BILLET-IR-CONSUMER-009"
      ];
    } ''touch "$out"'';

  "billet:kubernetes-grace-boundaries" = assert builtins.all (workload:
    qualifiedGrace workload 0 true
    && qualifiedGrace workload 1 true
    && qualifiedGrace workload 2 false
    && qualifiedGrace workload maximumGrace false
    && refusesGrace workload) ["deployment" "job"];
    pkgs.runCommand "billet-kubernetes-grace-boundaries" {
      passthru.bloomery = [
        "BILLET-IR-CONSUMER-010"
        "BILLET-IR-CONSUMER-011"
        "BILLET-IR-CONSUMER-012"
        "BILLET-IR-CONSUMER-013"
      ];
    } ''touch "$out"'';

  "billet:compose-cpu-engine-request" = assert refuses "UnsupportedComposeCpuLimit" cpuField overflowCpu.dockerCompose;
  assert refuses "UnsupportedComposeCpuLimit" "services.client.${cpuField}" (bundleFor overflowCpu).dockerCompose;
  assert overflowCpu.ir.resources.cpuLimit == maximumCpu + 1;
  assert renders (bundleFor cpuMaximum).dockerCompose;
    pkgs.runCommand "billet-compose-cpu-engine-request" {
      passthru.bloomery = ["BILLET-IR-CONSUMER-014" "BILLET-IR-CONSUMER-015"];
    } ''
      ${pkgs.python3}/bin/python3 ${./compose-engine-request.py} \
        ${pkgs.docker-compose}/bin/docker-compose ${cpuMaximum.dockerCompose.file} ${
        if pkgs.stdenv.hostPlatform.isAarch64
        then "arm64"
        else "amd64"
      }
      touch "$out"
    '';
}
