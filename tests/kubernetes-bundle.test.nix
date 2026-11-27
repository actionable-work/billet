{
  pkgs,
  billetLib,
  checkers,
  catalogBillets,
}: let
  inherit (pkgs) lib;
  inherit (import ./fixtures.nix {inherit pkgs billetLib;}) base evaluate;
  application = pkgs.runCommand "kubernetes-bundle-must-not-build" {} "exit 99";
  fixture = name: overrides:
    evaluate (lib.recursiveUpdate base (lib.recursiveUpdate {
        identity.name = name;
        process.package = application;
      }
      overrides));
  catalog = fixture "catalog" {
    kubernetes = {
      namespace = "bundle";
      createNamespace = true;
    };
  };
  report = fixture "report" {
    kubernetes = {
      namespace = "bundle";
      createNamespace = true;
      workload = "job";
    };
  };
  bundle = billets: (billetLib.mkBilletBundle {inherit pkgs billets;}).kubernetes;
  target = bundle {inherit catalog report;};
  job = billet: lib.findFirst (item: item.kind == "Job") null billet.kubernetes.configuration.items;
  revision = fixture "report" {
    kubernetes.workload = "job";
    process.argv = ["changed"];
  };
  disabledRestart = fixture "report" {
    kubernetes.workload = "job";
    restart.enabled = false;
  };
  invalidCount = fixture "report" {
    kubernetes.workload = "job";
    resources.replicas.max = 2;
  };
  conflictingNamespace = bundle {
    inherit catalog;
    report = fixture "report" {kubernetes.namespace = "other";};
  };
  inheritedNamespace = bundle {
    inherit catalog;
    report = fixture "report" {};
  };
  duplicateResources = bundle {
    inherit catalog;
    report = report // {kubernetes = catalog.kubernetes;};
  };
  invalidMember = bundle {
    inherit catalog;
    report = invalidCount;
  };
  rejects = code: field: candidate:
    !candidate.capabilityReport.canRender
    && builtins.any (item: item.code == code && item.field == field && item.severity == "error") candidate.capabilityReport.diagnostics
    && !(builtins.tryEval candidate.configuration).success;
  live = catalogBillets.catalog-report.kubernetes;
  members = ["catalog" "report"];
  parameters = pkgs.writeText "kubernetes-catalog-bundle.json" (builtins.toJSON {
    bundle = "${live.bundle}";
    kubernetesFile = "${live.file}";
    manifests = lib.genAttrs members (name: "${catalogBillets.${name}.manifest}");
    images = lib.genAttrs members (name: "${catalogBillets.${name}.dockerImage}");
  });
in {
  "billet:kubernetes-bundle-file" = assert target.capabilityReport.profile == "kubernetes-artifact-bundle-v1" && target.capabilityReport.canRender;
  assert target.capabilityReport.services.report == report.kubernetes.capabilityReport;
  assert lib.elem "job-completion" target.capabilityReport.supportedCapabilities;
  assert rejects "KubernetesJobReplicaCount" "services.report.resources.replicas" invalidMember;
  assert rejects "KubernetesBundleNamespaces" "services" conflictingNamespace;
  assert rejects "KubernetesBundleResourceCollision" "services" duplicateResources;
  assert builtins.all (item: item.kind == "Namespace" || item.metadata.namespace == "bundle") inheritedNamespace.configuration.items;
  assert (job report).spec.template.spec.restartPolicy == "Never";
  assert (job report).spec.backoffLimit == report.ir.restart.maxRetries;
  assert (job disabledRestart).spec.backoffLimit == 0;
  assert (job report).metadata.name != (job revision).metadata.name;
    pkgs.runCommand "billet-kubernetes-bundle-file" {
      nativeBuildInputs = [pkgs.jq];
      passthru.bloomery = [
        "BILLET-IR-KUBERNETES-093"
        "BILLET-IR-KUBERNETES-094"
        "BILLET-IR-KUBERNETES-095"
        "BILLET-IR-KUBERNETES-096"
        "BILLET-IR-KUBERNETES-097"
        "BILLET-IR-KUBERNETES-098"
        "BILLET-IR-KUBERNETES-099"
        "BILLET-IR-KUBERNETES-100"
        "BILLET-IR-KUBERNETES-101"
        "BILLET-IR-KUBERNETES-102"
        "BILLET-IR-KUBERNETES-103"
        "BILLET-IR-KUBERNETES-104"
        "BILLET-IR-KUBERNETES-105"
      ];
    } ''
      jq -e '.kind == "List" and .apiVersion == "v1" and ([.items[].kind] == ["Namespace", "Deployment", "Job"])' ${target.file}
      touch "$out"
    '';

  "billet:kubernetes-catalog-bundle" = pkgs.testers.runNixOSTest {
    name = "billet-kubernetes-catalog-bundle";
    passthru.bloomery = [
      "BILLET-IR-KUBERNETES-106"
      "BILLET-IR-KUBERNETES-107"
      "BILLET-IR-KUBERNETES-108"
      "BILLET-IR-KUBERNETES-109"
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
      machine.succeed("${checkers.kubernetes}/bin/billet-vm-kubernetes kubernetes-catalog-bundle ${parameters} >&2", timeout=1500)
    '';
  };
}
