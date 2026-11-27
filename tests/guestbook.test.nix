# Qualification for the stateful guestbook example. See
# PUBLIC/design/examples.md.
{
  pkgs,
  billetLib,
  harness,
  checkers,
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
  check = consumer: test: parameters: "${checkers.${consumer}}/bin/billet-vm-${consumer} ${test} ${pkgs.writeText "${test}.json" (builtins.toJSON parameters)} >&2";
  composeParameters = {
    inherit compose docker;
    bundle = "${dev.dockerCompose.bundle}";
    coreutils = "${pkgs.coreutils}";
    report = builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.toJSON dev.dockerCompose.capabilityReport));
  };
  kubernetesParameters = {
    bundle = "${prod.kubernetes.bundle}";
    coreutils = "${pkgs.coreutils}";
    manifests = lib.genAttrs members (name: "${prod.billets.${name}.manifest}");
  };
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
        machine.start()
        machine.wait_for_unit("docker.service")
        machine.succeed("${check "compose" "guestbook-compose" composeParameters}", timeout=900)
      '';
    };

    "billet:guestbook-kubernetes" = pkgs.testers.runNixOSTest {
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
        machine.start()
        machine.wait_for_unit("k3s.service")
        machine.succeed("${check "kubernetes" "guestbook-kubernetes" kubernetesParameters}", timeout=1200)
      '';
    };
  }
