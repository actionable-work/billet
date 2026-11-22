{
  pkgs,
  billetLib,
  harness ? null,
}: let
  inherit (pkgs) lib;
  maxSeconds = 9223372036;
  overflowSeconds = maxSeconds + 1;
  maxInteger = 9223372036854775807;
  maximum = "${toString maxSeconds}s";
  # Compose normalizes whole-second inputs using Go's native duration spelling.
  nativeMaximum = "2562047h47m16s";
  base = import ../examples/hello/application.nix {inherit pkgs;};
  # A successful consumer check can only depend on the Compose file. Realizing
  # this package (and consequently an application image) would fail the check.
  unrealizable = pkgs.runCommand "billet-compose-duration-must-not-build" {} "exit 99";
  make = extra:
    billetLib.mkBillet {
      inherit pkgs;
      modules = [
        (lib.recursiveUpdate base (lib.recursiveUpdate {
            process = {
              package = unrealizable;
              executable = "bin/application";
            };
          }
          extra))
      ];
    };
  execProbe = interval: timeout: {
    intervalSeconds = interval;
    timeoutSeconds = timeout;
    command = {
      package = unrealizable;
      executable = "bin/probe";
    };
  };
  networkProbe = {
    type = "tcp";
    port = "probe";
    intervalSeconds = overflowSeconds;
    timeoutSeconds = overflowSeconds;
  };
  withNetworkReadiness = extra:
    lib.recursiveUpdate {
      probes.readiness = networkProbe;
      network.ports.probe.port = 8080;
    }
    extra;
  bundleFor = billet:
    (billetLib.mkBilletBundle {
      inherit pkgs;
      billets = {
        ${billet.ir.identity.name} = billet;
        peer = make {identity.name = "peer";};
      };
    }).dockerCompose;
  service = billet: billet.dockerCompose.configuration.services.hello;
  durationErrors = report:
    map (item: {
      inherit (item) severity code field reason capability;
    }) (builtins.filter (item: item.code == "UnsupportedComposeDuration") report.diagnostics);
  expectedErrors = fields:
    map (field: {
      inherit field;
      severity = "error";
      code = "UnsupportedComposeDuration";
      reason = "exceeds the native Compose duration range";
      capability =
        if lib.hasSuffix "shutdown.stopGracePeriodSeconds" field
        then "shutdown"
        else "probes";
    })
    fields;
  refuses = target: fields: let
    report = target.capabilityReport;
  in
    !report.canRender
    && report.supportedCapabilities == []
    && lib.sort (a: b: a.field < b.field) (durationErrors report)
    == lib.sort (a: b: a.field < b.field) (expectedErrors fields)
    && !(builtins.tryEval (builtins.deepSeq target.configuration true)).success
    && !(builtins.tryEval target.file.drvPath).success
    && !(builtins.tryEval target.bundle.drvPath).success;
  refusesSingleAndBundle = billet: fields: let
    grouped = bundleFor billet;
    report = grouped.capabilityReport;
  in
    refuses billet.dockerCompose fields
    && refuses grouped (map (field: "services.hello.${field}") fields)
    && report.services.peer.canRender
    && report.services.hello == billet.dockerCompose.capabilityReport;
  accepts = billet:
    billet.dockerCompose.capabilityReport.canRender
    && (bundleFor billet).capabilityReport.canRender
    && durationErrors billet.dockerCompose.capabilityReport == [];
  warns = billet: code: field:
    builtins.any (item: item.severity == "warning" && item.code == code && item.field == field)
    billet.dockerCompose.capabilityReport.diagnostics;

  graceMaximum = make {shutdown.stopGracePeriodSeconds = maxSeconds;};
  graceZero = make {shutdown.stopGracePeriodSeconds = 0;};
  graceOverflow = make {shutdown.stopGracePeriodSeconds = overflowSeconds;};
  readinessMaximum = make {probes.readiness = execProbe maxSeconds maxSeconds;};
  livenessMaximum = make {probes.liveness = execProbe maxSeconds maxSeconds;};
  skippedReadinessMaximum = make (withNetworkReadiness {
    probes.liveness = execProbe maxSeconds maxSeconds;
  });
  intervalOverflow = role: make {probes.${role} = execProbe overflowSeconds 1;};
  skippedReadinessIntervalOverflow = make (withNetworkReadiness {
    probes.liveness = execProbe overflowSeconds 1;
  });
  # timeout <= interval is a portable IR constraint, so timeout overflow must
  # report both direct mapping errors instead of using an invalid IR fixture.
  bothOverflow = role: make {probes.${role} = execProbe overflowSeconds overflowSeconds;};
  skippedReadinessBothOverflow = make (withNetworkReadiness {
    probes.liveness = execProbe overflowSeconds overflowSeconds;
  });
  unselectedLiveness = make {
    probes = {
      readiness = execProbe 2 1;
      liveness = execProbe overflowSeconds overflowSeconds;
    };
  };
  unselectedStartup = make {
    probes = {
      readiness = execProbe 2 1;
      startup = (execProbe maxInteger overflowSeconds) // {failureThreshold = 2;};
    };
  };
  networkOnly = make (withNetworkReadiness {});
  allowanceOverflow = make {
    probes.readiness = execProbe 2 1;
    initialization.startupAllowanceSeconds = overflowSeconds;
  };
  overflowFields = role: ["probes.${role}.intervalSeconds" "probes.${role}.timeoutSeconds"];
  parse = file: output: ''
    ${pkgs.docker-compose}/bin/docker-compose --project-name billet-duration \
      --file ${file} config --format json > ${output}
  '';
  consumerInputs = [pkgs.jq];
in {
  selectorFixtures = let
    selectors = billet: {
      standalone = billet.dockerCompose;
      bundle = bundleFor billet;
    };
  in {
    readiness = selectors (make {
      shutdown.stopGracePeriodSeconds = overflowSeconds;
      probes.readiness = execProbe overflowSeconds overflowSeconds;
    });
    liveness = selectors skippedReadinessBothOverflow;
  };

  checks = {
    "billet:compose-duration-diagnostics" =
      pkgs.runCommand "billet-compose-duration-diagnostics" {
        passthru.bloomery = ["BILLET-IR-TARGETS-094" "BILLET-IR-TARGETS-095" "BILLET-IR-TARGETS-096"];
        nativeBuildInputs = [pkgs.nix];
        source = ../.;
        nixpkgsSource = pkgs.path;
        system = pkgs.stdenv.hostPlatform.system;
      } ''
        ${harness}/bin/billet-acceptance compose-durations
        touch "$out"
      '';

    # 094: zero and inclusive grace maximum survive the real consumer; max+1
    # remains valid IR but refuses all single/member-bundle artifact selectors.
    "billet:compose-duration-grace" = assert accepts graceMaximum && accepts graceZero;
    assert (service graceMaximum).stop_grace_period == maximum;
    assert (service graceZero).stop_grace_period == "0s";
    assert graceOverflow.ir.shutdown.stopGracePeriodSeconds == overflowSeconds;
    assert refusesSingleAndBundle graceOverflow ["shutdown.stopGracePeriodSeconds"];
      pkgs.runCommand "billet-compose-duration-grace" {
        passthru.bloomery = ["BILLET-IR-TARGETS-094" "BILLET-IR-TARGETS-097"];
        nativeBuildInputs = consumerInputs;
      } ''
          ${parse graceMaximum.dockerCompose.file "maximum.json"}
        jq -e '.services.hello.stop_grace_period == "${nativeMaximum}"' maximum.json
          ${parse graceZero.dockerCompose.file "zero.json"}
        jq -e '.services.hello.stop_grace_period == "0s"' zero.json
          ${parse (bundleFor graceMaximum).file "bundle.json"}
        jq -e '.services.hello.stop_grace_period == "${nativeMaximum}"' bundle.json
        touch "$out"
      '';

    # 095: the selected readiness or fallback liveness interval has its own
    # boundary. Network readiness is skipped; unmapped intervals remain portable.
    "billet:compose-duration-interval" = assert builtins.all accepts [readinessMaximum livenessMaximum skippedReadinessMaximum];
    assert builtins.all (billet: (service billet).healthcheck.interval == maximum) [readinessMaximum livenessMaximum skippedReadinessMaximum];
    assert builtins.all (role:
      (intervalOverflow role).ir.probes.${role}.intervalSeconds
      == overflowSeconds
      && refusesSingleAndBundle (intervalOverflow role) ["probes.${role}.intervalSeconds"])
    ["readiness" "liveness"];
    assert refusesSingleAndBundle skippedReadinessIntervalOverflow ["probes.liveness.intervalSeconds"];
    assert builtins.all accepts [unselectedLiveness unselectedStartup networkOnly allowanceOverflow];
    assert unselectedLiveness.ir.probes.liveness.intervalSeconds == overflowSeconds;
    assert (service unselectedLiveness).healthcheck.interval == "2s";
    assert unselectedStartup.ir.probes.startup.intervalSeconds == maxInteger;
    assert (service unselectedStartup).healthcheck.start_period == maximum;
    assert warns unselectedStartup "ComposeStartupWindowLimited" "probes.startup";
    assert (service allowanceOverflow).healthcheck.start_period == maximum;
    assert warns allowanceOverflow "ComposeStartupWindowLimited" "initialization.startupAllowanceSeconds";
    assert networkOnly.ir.probes.readiness.intervalSeconds == overflowSeconds;
    assert !((service networkOnly) ? healthcheck);
    assert warns skippedReadinessMaximum "UnsupportedComposeNetworkProbe" "probes.readiness.type";
      pkgs.runCommand "billet-compose-duration-interval" {
        passthru.bloomery = ["BILLET-IR-TARGETS-095" "BILLET-IR-TARGETS-098"];
        nativeBuildInputs = consumerInputs;
      } ''
          ${parse readinessMaximum.dockerCompose.file "readiness.json"}
          ${parse livenessMaximum.dockerCompose.file "liveness.json"}
          ${parse skippedReadinessMaximum.dockerCompose.file "skipped-readiness.json"}
        for configuration in readiness.json liveness.json skipped-readiness.json; do
          jq -e '.services.hello.healthcheck.interval == "${nativeMaximum}"' "$configuration"
        done
          ${parse unselectedStartup.dockerCompose.file "startup.json"}
          ${parse allowanceOverflow.dockerCompose.file "allowance.json"}
        for configuration in startup.json allowance.json; do
          jq -e '.services.hello.healthcheck.start_period == "${nativeMaximum}"' "$configuration"
        done
        touch "$out"
      '';

    # 096: timeout's inclusive consumer boundary and exact field errors for both
    # overflow values, with no new bound on unselected or network probe timeouts.
    "billet:compose-duration-timeout" = assert builtins.all (billet: accepts billet && (service billet).healthcheck.timeout == maximum) [readinessMaximum livenessMaximum skippedReadinessMaximum];
    assert builtins.all (role:
      (bothOverflow role).ir.probes.${role}.timeoutSeconds
      == overflowSeconds
      && refusesSingleAndBundle (bothOverflow role) (overflowFields role))
    ["readiness" "liveness"];
    assert refusesSingleAndBundle skippedReadinessBothOverflow (overflowFields "liveness");
    assert builtins.all accepts [unselectedLiveness unselectedStartup networkOnly];
    assert unselectedLiveness.ir.probes.liveness.timeoutSeconds == overflowSeconds;
    assert unselectedStartup.ir.probes.startup.timeoutSeconds == overflowSeconds;
    assert networkOnly.ir.probes.readiness.timeoutSeconds == overflowSeconds;
    assert (service unselectedLiveness).healthcheck.timeout == "1s";
    assert (service unselectedStartup).healthcheck.timeout == "1s";
      pkgs.runCommand "billet-compose-duration-timeout" {
        passthru.bloomery = ["BILLET-IR-TARGETS-096" "BILLET-IR-TARGETS-099"];
        nativeBuildInputs = consumerInputs;
      } ''
          ${parse readinessMaximum.dockerCompose.file "readiness.json"}
          ${parse livenessMaximum.dockerCompose.file "liveness.json"}
          ${parse skippedReadinessMaximum.dockerCompose.file "skipped-readiness.json"}
        for configuration in readiness.json liveness.json skipped-readiness.json; do
          jq -e '.services.hello.healthcheck.timeout == "${nativeMaximum}"' "$configuration"
        done
          ${parse unselectedLiveness.dockerCompose.file "unselected.json"}
        jq -e '.services.hello.healthcheck.timeout == "1s"' unselected.json
          ${parse networkOnly.dockerCompose.file "network.json"}
        jq -e '.services.hello | has("healthcheck") | not' network.json
        touch "$out"
      '';
  };
}
