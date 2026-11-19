{
  pkgs,
  billetLib,
  catalogBillets,
}: let
  inherit (pkgs) lib;
  inherit (import ./fixtures.nix {inherit pkgs billetLib;}) base evaluate;
  trap = pkgs.runCommand "microvm-bundle-must-not-build" {} "exit 99";
  make = name: settings:
    evaluate (lib.recursiveUpdate base (lib.recursiveUpdate {
        identity.name = name;
        process.package = trap;
      }
      settings));
  link = {
    sourceService = "report";
    destinationService = "catalog";
    destinationPort = "http";
    protocol = "http";
  };
  catalog = make "catalog" {
    network.ports.http = {
      port = 8080;
      protocol = "http";
    };
    network.privateConnections = [link];
  };
  report = make "report" {};
  target = settings: billets:
    (billetLib.mkBilletBundle {
      inherit pkgs billets;
      microvm = settings;
    }).microvm;
  rendered = target {hostPortBase = 19000;} {inherit catalog report;};
  single = target {} {inherit catalog;};
  catalogVm = rendered.configuration.services.catalog.guest;
  reportVm = rendered.configuration.services.report.guest;
  refersTo = code: field: candidate: builtins.any (item: item.code == code && item.field == field) candidate.capabilityReport.diagnostics;
  rejects = code: field: candidate: refersTo code field candidate && !candidate.capabilityReport.canRender && !(builtins.tryEval candidate.configuration).success;
  conflictingLink = make "report" {network.privateConnections = [(link // {protocol = "tcp";})];};
  restrictive = make "report" {network.publicEgress = false;};
  live = catalogBillets.catalog-report.microvm;
  inheritedHost = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = null;
    modules = [
      {
        nixpkgs.pkgs = pkgs;
        system.stateVersion = "26.05";
      }
      rendered.hostModule
    ];
  };
in {
  "billet:microvm-bundle-file" = assert rendered.capabilityReport.profile == "microvm-artifact-bundle-v1" && rendered.capabilityReport.canRender;
  assert rendered.capabilityReport.services.catalog == catalog.microvm.capabilityReport;
  assert builtins.elem "loopback-private-links" rendered.capabilityReport.supportedCapabilities;
  assert rejects "MicrovmBundleLink" "services.report.network.privateConnections" (target {} {
    inherit catalog;
    report = conflictingLink;
  });
  assert rejects "MicrovmBundleHostPorts" "microvm.hostPortBase" (target {hostPortBase = 65536;} {inherit catalog report;});
  assert rejects "MicrovmBundleEgress" "services.report.network.publicEgress" (target {} {
    inherit catalog;
    report = restrictive;
  });
  assert rejects "MicrovmBundleMemberName" "services.UPPER.identity.name" (target {} {UPPER = make "UPPER" {};});
  assert refersTo "MicrovmBundleExternalLink" "services.catalog.network.privateConnections" single && single.capabilityReport.canRender;
  assert single.configuration.services.catalog.guest.microvm.interfaces == [];
  assert catalogVm.networking.hostName == "catalog" && reportVm.networking.hostName == "report";
  assert catalogVm.microvm.forwardPorts
  == [
    {
      from = "host";
      host = {
        address = "127.0.0.1";
        port = 19000;
      };
      guest.port = 8080;
    }
  ];
  assert reportVm.networking.hosts."10.0.2.100" == ["catalog"];
  assert reportVm.systemd.services.billet.after == ["network-online.target"];
  assert inheritedHost.config.systemd.targets.microvms.wants == ["microvm@catalog.service" "microvm@report.service"];
    pkgs.runCommand "billet-microvm-bundle-file" {
      nativeBuildInputs = [pkgs.jq];
      passthru.bloomery = [
        "BILLET-IR-MICROVM-059"
        "BILLET-IR-MICROVM-060"
        "BILLET-IR-MICROVM-061"
        "BILLET-IR-MICROVM-062"
        "BILLET-IR-MICROVM-063"
        "BILLET-IR-MICROVM-064"
        "BILLET-IR-MICROVM-065"
        "BILLET-IR-MICROVM-066"
        "BILLET-IR-MICROVM-067"
        "BILLET-IR-MICROVM-068"
        "BILLET-IR-MICROVM-069"
        "BILLET-IR-MICROVM-070"
        "BILLET-IR-MICROVM-071"
        "BILLET-IR-MICROVM-072"
        "BILLET-IR-MICROVM-073"
      ];
    } ''
      jq -e --argjson expected ${lib.escapeShellArg (builtins.unsafeDiscardStringContext (builtins.toJSON rendered.configuration))} \
        '. == $expected and .services.catalog.runner == "guests/catalog/runner"' ${rendered.file}
      touch "$out"
    '';

  "billet:microvm-catalog-bundle" =
    pkgs.runCommand "billet-microvm-catalog-bundle" {
      nativeBuildInputs = [pkgs.curl];
      passthru.bloomery = [
        "BILLET-IR-MICROVM-074"
        "BILLET-IR-MICROVM-075"
        "BILLET-IR-MICROVM-076"
        "BILLET-IR-MICROVM-077"
        "BILLET-IR-MICROVM-078"
      ];
    } ''
      cmp ${live.file} ${live.bundle}/microvm.json
      ${lib.concatMapStringsSep "\n" (name: ''
        cmp ${catalogBillets.${name}.manifest} ${live.bundle}/manifests/${name}.json
        test "$(readlink ${live.bundle}/guests/${name}/runner)" = ${live.hostModule.microvm.vms.${name}.evaluatedConfig.config.microvm.declaredRunner}
      '') ["catalog" "report"]}

      mkdir catalog report
      catalog_pid=
      report_pid=
      cleanup() {
        for pid in "$catalog_pid" "$report_pid"; do
          if test -n "$pid"; then kill "$pid" 2>/dev/null || true; fi
        done
      }
      diagnose() {
        cleanup
        cat catalog/console.log report/console.log 2>/dev/null | tr -d '\r' || true
      }
      trap diagnose EXIT
      (cd catalog && exec timeout -k 5s 250s ${live.bundle}/guests/catalog/runner/bin/microvm-run) </dev/null >catalog/console.log 2>&1 &
      catalog_pid=$!
      inventory='{"items":[{"inStock":true,"sku":"notebook"}]}'
      until test "$(curl -fsS --max-time 2 http://127.0.0.1:18080/items.json 2>/dev/null)" = "$inventory"; do
        kill -0 "$catalog_pid"
        sleep 1
      done
      (cd report && exec timeout -k 5s 180s ${live.bundle}/guests/report/runner/bin/microvm-run) </dev/null >report/console.log 2>&1 &
      report_pid=$!
      until grep -Fq "$inventory" report/console.log; do
        kill -0 "$report_pid"
        sleep 1
      done
      cleanup
      mkdir -p "$out"
      cp catalog/console.log "$out/catalog.log"
      cp report/console.log "$out/report.log"
      trap - EXIT
    '';
}
