{
  pkgs,
  billetLib,
}: let
  inherit (pkgs) lib;
  fixtures = import ./fixtures.nix {inherit pkgs billetLib;};
  make = extra: fixtures.evaluate (lib.recursiveUpdate fixtures.base extra);
  base = make {};
  unset = make {
    network.bandwidth = {
      ingress.minBitsPerSecond = null;
      egress.maxBitsPerSecond = null;
    };
  };
  minimum = make {network.bandwidth.egress.minBitsPerSecond = 1;};
  ingressMinimum = make {network.bandwidth.ingress.minBitsPerSecond = 2;};
  maximum = make {network.bandwidth.ingress.maxBitsPerSecond = 1000;};
  allRates = {
    ingress = {
      minBitsPerSecond = 100000000;
      maxBitsPerSecond = 500000000;
    };
    egress = {
      minBitsPerSecond = 200000000;
      maxBitsPerSecond = 200000000;
    };
  };
  combined = make {network.bandwidth = allRates;};
  combinedBundle = billetLib.mkBilletBundle {
    inherit pkgs;
    billets.hello = combined;
  };
  cap = "network-bandwidth-limits";
  reservation = "network-bandwidth-reservations";
  has = builtins.elem;
  optIn = {kubernetes.bandwidthProfile = "pod-annotations";};
  ingressOnly = make (optIn // {network.bandwidth.ingress.maxBitsPerSecond = 1000;});
  maximumWithProfile = make (optIn
    // {
      network.ports.web = {
        port = 8080;
        exposure = "public";
      };
      network.bandwidth = {
        ingress.maxBitsPerSecond = 1000;
        egress.maxBitsPerSecond = 1000000000000000;
      };
    });
  job = make (lib.recursiveUpdate optIn {
    kubernetes.workload = "job";
    network.bandwidth.egress.maxBitsPerSecond = 120000000;
  });
  kubeBundle = billetLib.mkBilletBundle {
    inherit pkgs;
    billets.hello = maximumWithProfile;
  };
  report = maximumWithProfile.kubernetes.capabilityReport;
  mixedRequest = make (optIn // {network.bandwidth = allRates;});
  rejectMin = mixedRequest.kubernetes.capabilityReport;
  reservedBundle =
    (billetLib.mkBilletBundle {
      inherit pkgs;
      billets.hello = mixedRequest;
    }).kubernetes;
  rejectBundle = reservedBundle.capabilityReport;
  invalidRange =
    (make (optIn
      // {
        network.bandwidth = {
          ingress.maxBitsPerSecond = 999;
          egress.maxBitsPerSecond = 1000000000000001;
        };
      })).kubernetes.capabilityReport;
  diagnostic = target: severity: code: capability: field: reason:
    builtins.any (item:
      item.code
      == code
      && item.capability == capability
      && item.field == field
      && item.severity == severity
      && lib.hasInfix reason item.reason)
    target.diagnostics;
  directions = ["ingress" "egress"];
  rejectsReservation = target: prefix:
    builtins.all (direction:
      diagnostic target "error" "KubernetesBandwidthReservation" reservation "${prefix}network.bandwidth.${direction}.minBitsPerSecond" "cannot reserve network bandwidth")
    directions;
  workload = kind: billet: lib.findFirst (item: item.kind == kind) (throw "missing ${kind}") billet.kubernetes.configuration.items;
  deployment = workload "Deployment" maximumWithProfile;
  workloadJob = workload "Job" job;
  annotations = deployment.spec.template.metadata.annotations;
  jobAnnotations = workloadJob.spec.template.metadata.annotations;
  renderedItems = maximumWithProfile.kubernetes.configuration.items;
  podOnly = key:
    builtins.all (item: !(builtins.hasAttr key (item.metadata.annotations or {}))) renderedItems;
  consumerDiagnostics = code: prefix: target: let
    warning = capability: field:
      diagnostic target "warning" code capability "${prefix}${field}" "requires consumer-managed networking";
  in
    builtins.all (direction:
      warning reservation "network.bandwidth.${direction}.minBitsPerSecond"
      && warning cap "network.bandwidth.${direction}.maxBitsPerSecond")
    directions;
  consumerCapabilities = target:
    has cap target.requiredCapabilities
    && has reservation target.requiredCapabilities
    && !(has cap target.supportedCapabilities)
    && !(has reservation target.supportedCapabilities);
  compose = combined.dockerCompose.capabilityReport;
  composeBundle = combinedBundle.dockerCompose.capabilityReport;
  microvm = combined.microvm.capabilityReport;
  microvmBundle = combinedBundle.microvm.capabilityReport;
in {
  "billet:bandwidth-ir" = assert !(base.ir.network ? bandwidth);
  assert unset.canonicalJSON == base.canonicalJSON && unset.manifestDigest == base.manifestDigest;
  assert minimum.ir.network.bandwidth == {egress.minBitsPerSecond = 1;};
  assert ingressMinimum.ir.network.bandwidth == {ingress.minBitsPerSecond = 2;};
  assert maximum.ir.network.bandwidth == {ingress.maxBitsPerSecond = 1000;};
  assert job.ir.network.bandwidth == {egress.maxBitsPerSecond = 120000000;};
  assert (builtins.fromJSON (builtins.unsafeDiscardStringContext combined.canonicalJSON)).network.bandwidth == allRates;
  assert has reservation minimum.ir.requiredCapabilities && !(has cap minimum.ir.requiredCapabilities);
  assert has reservation ingressMinimum.ir.requiredCapabilities && !(has cap ingressMinimum.ir.requiredCapabilities);
  assert has cap maximum.ir.requiredCapabilities && !(has reservation maximum.ir.requiredCapabilities);
  assert has cap job.ir.requiredCapabilities && !(has reservation job.ir.requiredCapabilities);
  assert has reservation combined.ir.requiredCapabilities && has cap combined.ir.requiredCapabilities;
  assert (make optIn).canonicalJSON == base.canonicalJSON;
    pkgs.runCommand "billet-bandwidth-ir" {
      passthru.bloomery = [
        "BILLET-IR-BANDWIDTH-001"
        "BILLET-IR-BANDWIDTH-002"
        "BILLET-IR-BANDWIDTH-003"
        "BILLET-IR-BANDWIDTH-004"
        "BILLET-IR-BANDWIDTH-005"
        "BILLET-IR-BANDWIDTH-006"
        "BILLET-IR-BANDWIDTH-036"
        "BILLET-IR-BANDWIDTH-037"
        "BILLET-IR-BANDWIDTH-039"
      ];
    } ''touch "$out"'';

  "billet:bandwidth-kubernetes" = assert !rejectMin.canRender && !(builtins.tryEval mixedRequest.kubernetes.configuration).success;
  assert rejectsReservation rejectMin "";
  assert !maximum.kubernetes.capabilityReport.canRender;
  assert diagnostic maximum.kubernetes.capabilityReport "error" "KubernetesBandwidthProfile" cap "kubernetes.bandwidthProfile" "set to pod-annotations";
  assert !invalidRange.canRender;
  assert builtins.all (direction: diagnostic invalidRange "error" "KubernetesBandwidthRange" cap "network.bandwidth.${direction}.maxBitsPerSecond" "must be in 1000..1000000000000000 bits per second") directions;
  assert annotations."kubernetes.io/ingress-bandwidth" == "1000";
  assert annotations."kubernetes.io/egress-bandwidth" == "1000000000000000";
  assert jobAnnotations."kubernetes.io/egress-bandwidth" == "120000000";
  assert has "Service" (lib.catAttrs "kind" renderedItems) && has "NetworkPolicy" (lib.catAttrs "kind" renderedItems);
  assert podOnly "kubernetes.io/ingress-bandwidth" && podOnly "kubernetes.io/egress-bandwidth";
  assert !(workloadJob.metadata.annotations ? "kubernetes.io/egress-bandwidth");
  assert diagnostic report "warning" "KubernetesBandwidthCNI" cap "kubernetes.bandwidthProfile" "requires a cluster networking plugin configured for Pod bandwidth annotations";
  assert report.canRender && has cap report.requiredCapabilities && has cap report.supportedCapabilities;
  assert !(jobAnnotations ? "kubernetes.io/ingress-bandwidth");
  assert !((workload "Deployment" ingressOnly).spec.template.metadata.annotations ? "kubernetes.io/egress-bandwidth");
  assert !rejectBundle.canRender && !(builtins.tryEval reservedBundle.configuration).success;
  assert rejectsReservation rejectBundle "services.hello.";
    pkgs.runCommand "billet-bandwidth-kubernetes" {
      passthru.bloomery = [
        "BILLET-IR-BANDWIDTH-010"
        "BILLET-IR-BANDWIDTH-011"
        "BILLET-IR-BANDWIDTH-012"
        "BILLET-IR-BANDWIDTH-013"
        "BILLET-IR-BANDWIDTH-014"
        "BILLET-IR-BANDWIDTH-015"
        "BILLET-IR-BANDWIDTH-016"
        "BILLET-IR-BANDWIDTH-017"
        "BILLET-IR-BANDWIDTH-018"
        "BILLET-IR-BANDWIDTH-035"
        "BILLET-IR-BANDWIDTH-038"
      ];
    } ''touch "$out"'';

  "billet:bandwidth-consumer-reports" = assert consumerDiagnostics "ComposeBandwidth" "" compose;
  assert consumerDiagnostics "ComposeBandwidth" "services.hello." composeBundle;
  assert consumerDiagnostics "MicrovmBandwidth" "" microvm;
  assert consumerDiagnostics "MicrovmBandwidth" "services.hello." microvmBundle;
  assert consumerCapabilities compose && consumerCapabilities composeBundle;
  assert consumerCapabilities microvm && consumerCapabilities microvmBundle;
  assert compose.canRender && composeBundle.canRender;
  assert microvm.canRender && microvmBundle.canRender;
    pkgs.runCommand "billet-bandwidth-consumer-reports" {
      passthru.bloomery = [
        "BILLET-IR-BANDWIDTH-019"
        "BILLET-IR-BANDWIDTH-020"
        "BILLET-IR-BANDWIDTH-021"
        "BILLET-IR-BANDWIDTH-022"
        "BILLET-IR-BANDWIDTH-040"
        "BILLET-IR-BANDWIDTH-041"
        "BILLET-IR-BANDWIDTH-042"
        "BILLET-IR-BANDWIDTH-043"
      ];
    } ''touch "$out"'';

  "billet:bandwidth-manifests" =
    pkgs.runCommand "billet-bandwidth-manifests" {
      nativeBuildInputs = [pkgs.jq];
      passthru.bloomery = [
        "BILLET-IR-BANDWIDTH-023"
        "BILLET-IR-BANDWIDTH-024"
        "BILLET-IR-BANDWIDTH-025"
        "BILLET-IR-BANDWIDTH-026"
        "BILLET-IR-BANDWIDTH-027"
        "BILLET-IR-BANDWIDTH-028"
      ];
    } ''
      image=${combined.dockerImage}
      layer=$(tar -xOf "$image" manifest.json | jq -er '.[0].Layers[-1]')
      tar -xOf "$image" "$layer" > metadata.tar
      manifestPath=$(tar -tf metadata.tar | grep -E '(^|/)etc/billet/manifest\.json$')
      tar -xOf metadata.tar "$manifestPath" > image-manifest.json
      cmp ${combined.manifest} image-manifest.json
      cmp ${combined.manifest} ${combined.dockerCompose.bundle}/manifest.json
      cmp ${combined.manifest} ${combinedBundle.dockerCompose.bundle}/manifests/hello.json
      cmp ${combined.manifest} ${combined.microvm.bundle}/manifest.json
      cmp ${combined.manifest} ${combinedBundle.microvm.bundle}/manifests/hello.json
      cmp ${maximumWithProfile.manifest} ${kubeBundle.kubernetes.bundle}/manifests/hello.json
      touch "$out"
    '';
}
