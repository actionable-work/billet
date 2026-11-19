{
  pkgs,
  billetLib,
}: let
  inherit (pkgs) lib;
  fixtures = import ./fixtures.nix {inherit pkgs billetLib;};
  inherit (fixtures) evaluate;
  trap = pkgs.runCommand "microvm-must-not-build-application" {} "exit 99";
  module = lib.recursiveUpdate fixtures.full {
    process = {
      package = trap;
      workingDirectory = "/working/%n";
    };
    network = {
      privateConnections = [
        {
          sourceService = "peer";
          destinationService = "hello";
          destinationPort = "web";
        }
      ];
      publicEgress = false;
      egressRestrictions = ["consumer-rule"];
    };
    resources = {
      cpuLimit = 1001;
      memoryLimit = 67108865;
      targetMetric = "work-queue";
      strictSingleton = true;
    };
    rollout = {
      maxSurge = 0;
      maxUnavailable = 1;
    };
    shutdown.stopGracePeriodSeconds = 0;
  };
  billet = evaluate module;
  inherit (billet.microvm) configuration capabilityReport file;
  service = configuration.systemd.services.billet.serviceConfig;
  alternate = overrides: (evaluate (lib.recursiveUpdate module overrides)).microvm;
  diagnosed = severity: field: report: builtins.any (item: item.severity == severity && item.field == field) report.diagnostics;
  warns = field: diagnosed "warning" field capabilityReport;
  refuses = field: target:
    !target.capabilityReport.canRender
    && target.capabilityReport.supportedCapabilities == []
    && diagnosed "error" field target.capabilityReport
    && builtins.all (attempt: !attempt.success) (map (name: builtins.tryEval target.${name}) ["configuration" "file" "runner" "bundle"]);
  darwin = import pkgs.path {system = "aarch64-darwin";};
  unsupported = billetLib.mkBillet {
    pkgs = darwin;
    modules = [../examples/hello/application.nix];
  };
  assertions = {
    "001" =
      capabilityReport.target
      == "microvm"
      && capabilityReport.profile == "microvm-artifact-v1"
      && capabilityReport.mode == "artifact-only"
      && capabilityReport.profileVersion == 1
      && capabilityReport.rendererVersion == 1
      && capabilityReport.schemaVersion == 1;
    "002" = capabilityReport.system == pkgs.stdenv.hostPlatform.system;
    "003" = capabilityReport.manifestDigest == billet.manifestDigest;
    "004" = capabilityReport.requiredCapabilities == billet.ir.requiredCapabilities;
    "005" = capabilityReport.canRender && capabilityReport.supportedCapabilities == ["process-tree-cleanup" "resource-limits" "shutdown"];
    "006" = refuses "systems" unsupported.microvm;
    "007" = builtins.all (user: refuses "process.user" (alternate {process.user = user;})) ["named-user" "00:1" "65535:0" "1:4294967295"];
    "008" = refuses "process.executable" (alternate {process.executable = "bin/invalid\nline";});
    "009" = refuses "process.workingDirectory" (alternate {process.workingDirectory = "/tmp\\";});
    "010" = refuses "resources.cpuLimit" (alternate {resources.cpuLimit = 64001;});
    "011" = refuses "resources.memoryLimit" (alternate {resources.memoryLimit = 1099511627777;});
    "012" = refuses "shutdown.stopGracePeriodSeconds" (alternate {shutdown.stopGracePeriodSeconds = 18446744073710;});
    "013" = configuration.microvm.hypervisor == "qemu" && !(configuration.microvm ? cpu) && !(configuration.microvm ? qemu);
    "014" = let
      vm = (alternate {microvm.acceleration = "tcg";}).configuration.microvm;
    in
      vm.cpu == "max" && vm.qemu.machineOpts.accel == "tcg";
    "015" = configuration.microvm.vcpu == 2;
    "016" = configuration.microvm.mem == 577;
    "017" = service.TimeoutStopSec == "1us";
    "018" = service.KillMode == "control-group";
    "019" = configuration.microvm.interfaces == [];
    "020" = service.WorkingDirectory == "/working/%%n";
    "021" = configuration.microvm.storeOnDisk;
    "022" = service.Restart == "no";
    "023" = warns "resources.cpuRequest";
    "024" = warns "resources.memoryRequest";
    "025" = warns "rollout";
    "026" = warns "initialization.steps";
    "027" = warns "probes.readiness" && !warns "probes.liveness";
    "028" = warns "restart" && !(diagnosed "warning" "restart" (alternate {restart.enabled = false;}).capabilityReport);
    "029" =
      diagnosed "warning" "resources.replicas"
      (alternate {resources.replicas.min = 0;}).capabilityReport;
    "030" = warns "resources.targetMetric";
    "031" = warns "resources.placement";
    "032" = warns "resources.strictSingleton";
    "033" = warns "network.ports";
    "034" = warns "network.privateConnections";
    "035" = warns "network.publicEgress";
    "036" = warns "network.egressRestrictions";
    "037" = warns "storage.scratch";
    "038" = warns "secrets.database" && warns "secrets.token";
    "039" = service.Environment == [(builtins.toJSON "DATA=${fixtures.data}")];
    "055" = (alternate {shutdown.stopGracePeriodSeconds = 7;}).configuration.systemd.services.billet.serviceConfig.TimeoutStopSec == "7s";
    "056" = let
      report = (alternate {process.user = "DO-NOT-ECHO-USER";}).capabilityReport;
    in
      !lib.hasInfix "DO-NOT-ECHO-USER" (builtins.toJSON report);
    "057" = configuration.users.users == {};
    "058" = configuration.users.groups == {};
    "079" = let
      memory = limit: (alternate {resources.memoryLimit = limit;}).configuration.microvm.mem;
    in
      memory (1536 * 1024 * 1024) == 2049 && memory (1535 * 1024 * 1024) == 2047 && memory (1537 * 1024 * 1024) == 2049;
  };
  qualification.passthru.bloomery = [
    "BILLET-IR-MICROVM-001"
    "BILLET-IR-MICROVM-002"
    "BILLET-IR-MICROVM-003"
    "BILLET-IR-MICROVM-004"
    "BILLET-IR-MICROVM-005"
    "BILLET-IR-MICROVM-006"
    "BILLET-IR-MICROVM-007"
    "BILLET-IR-MICROVM-008"
    "BILLET-IR-MICROVM-009"
    "BILLET-IR-MICROVM-010"
    "BILLET-IR-MICROVM-011"
    "BILLET-IR-MICROVM-012"
    "BILLET-IR-MICROVM-013"
    "BILLET-IR-MICROVM-014"
    "BILLET-IR-MICROVM-015"
    "BILLET-IR-MICROVM-016"
    "BILLET-IR-MICROVM-017"
    "BILLET-IR-MICROVM-018"
    "BILLET-IR-MICROVM-019"
    "BILLET-IR-MICROVM-020"
    "BILLET-IR-MICROVM-021"
    "BILLET-IR-MICROVM-022"
    "BILLET-IR-MICROVM-023"
    "BILLET-IR-MICROVM-024"
    "BILLET-IR-MICROVM-025"
    "BILLET-IR-MICROVM-026"
    "BILLET-IR-MICROVM-027"
    "BILLET-IR-MICROVM-028"
    "BILLET-IR-MICROVM-029"
    "BILLET-IR-MICROVM-030"
    "BILLET-IR-MICROVM-031"
    "BILLET-IR-MICROVM-032"
    "BILLET-IR-MICROVM-033"
    "BILLET-IR-MICROVM-034"
    "BILLET-IR-MICROVM-035"
    "BILLET-IR-MICROVM-036"
    "BILLET-IR-MICROVM-037"
    "BILLET-IR-MICROVM-038"
    "BILLET-IR-MICROVM-039"
    "BILLET-IR-MICROVM-055"
    "BILLET-IR-MICROVM-056"
    "BILLET-IR-MICROVM-057"
    "BILLET-IR-MICROVM-058"
    "BILLET-IR-MICROVM-079"
  ];
in {
  "billet:microvm-configuration" = assert qualification.passthru.bloomery == map (number: "BILLET-IR-MICROVM-${number}") (builtins.attrNames assertions);
  assert lib.foldlAttrs (ok: number: passed:
    if passed
    then ok
    else throw "microVM assertion ${number} failed")
  true
  assertions;
    pkgs.runCommand "billet-microvm-configuration" qualification "touch $out";
  "billet:microvm-file" =
    pkgs.runCommand "billet-microvm-file" {
      passthru.bloomery = ["BILLET-IR-MICROVM-040"];
      nativeBuildInputs = [pkgs.jq];
    } ''
      jq -e --argjson expected ${lib.escapeShellArg (builtins.unsafeDiscardStringContext (builtins.toJSON configuration))} \
        '. == $expected' ${file}
      touch "$out"
    '';
}
