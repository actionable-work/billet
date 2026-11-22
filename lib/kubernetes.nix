{
  pkgs,
  billet,
  oci,
  imageEligibility,
  settings,
}: let
  inherit (pkgs) lib;
  inherit (billet) ir manifestDigest;
  inherit (ir) identity resources rollout;
  inherit (settings) namespace createNamespace;
  isJob = settings.workload == "job";
  jobRetries =
    if ir.restart.enabled && builtins.elem "unexpected-exit" ir.restart.triggers
    then ir.restart.maxRetries
    else 0;
  hash = value: builtins.hashString "sha256" (builtins.toJSON value);
  applicationName = value:
    if
      builtins.stringLength value
      <= 63
      && builtins.match "[a-z]([-a-z0-9]*[a-z0-9])?" value != null
      && value != "kubernetes"
      && !lib.hasPrefix "billet-x-" value
      && !lib.hasPrefix "billet-public-" value
    then value
    else "billet-x-${builtins.substring 0 54 (hash value)}";
  name = applicationName identity.name;
  labelsFor = value: {"billet.actionable.work/application" = applicationName value;};
  labels = labelsFor identity.name;
  annotations = {
    "billet.actionable.work/identity-name" = identity.name;
    "billet.actionable.work/identity-version" = identity.version;
    "billet.actionable.work/manifest-digest" = builtins.unsafeDiscardStringContext manifestDigest;
  };
  annotationBytes =
    lib.foldlAttrs (total: key: value:
      total + builtins.stringLength key + builtins.stringLength value)
    0
    annotations;
  warning = code: capability: field: reason: {
    inherit code capability field reason;
    severity = "warning";
  };
  error = code: capability: field: reason: {
    inherit code capability field reason;
    severity = "error";
  };
  bandwidth = ir.network.bandwidth or {};
  bandwidthMaxima = lib.mapAttrs (_: rates: rates.maxBitsPerSecond) (
    lib.filterAttrs (_: rates: rates ? maxBitsPerSecond) bandwidth
  );
  useBandwidthAnnotations = settings.bandwidthProfile == "pod-annotations";
  bandwidthAnnotations = lib.mapAttrs' (direction: rate:
    lib.nameValuePair "kubernetes.io/${direction}-bandwidth" (toString rate))
  bandwidthMaxima;

  network = import ./kubernetes-network.nix {inherit lib ir name labels labelsFor hash warning;};
  # Kubelet projects variables from default/kubernetes even with service
  # links disabled. Match the names derived from the Service and its ports.
  isAPIServiceEnv = name:
    builtins.match "KUBERNETES_(SERVICE_HOST|SERVICE_PORT(_[A-Z0-9_]+)?|PORT(_[1-9][0-9]{0,4}_(TCP|UDP|SCTP)(_(PROTO|PORT|ADDR))?)?)" name != null;
  mounts = import ./kubernetes-mounts.nix {inherit lib ir hash warning error isAPIServiceEnv;};
  validNamespace =
    namespace
    == null
    || (builtins.stringLength namespace
      <= 63
      && builtins.match "[a-z0-9]([-a-z0-9]*[a-z0-9])?" namespace != null);
  serviceAccountMount = "/var/run/secrets/kubernetes.io/serviceaccount";
  overlapsServiceAccountMount = builtins.any (mount:
    mount.mountPath
    == serviceAccountMount
    || lib.hasPrefix "${serviceAccountMount}/" mount.mountPath
    || lib.hasPrefix "${mount.mountPath}/" serviceAccountMount)
  mounts.volumeMounts;

  int32Max = 2147483647;
  userParts = map builtins.fromJSON (lib.splitString ":" ir.process.user);
  int32Fields =
    (
      if isJob
      then {
        "restart.maxRetries" = jobRetries;
      }
      else {
        "resources.replicas.min" = resources.replicas.min;
        "rollout.minReadySeconds" = rollout.minReadySeconds;
        "rollout.progressDeadlineSeconds" = rollout.progressDeadlineSeconds;
      }
    )
    // lib.optionalAttrs (!isJob && !resources.strictSingleton) {
      "rollout.maxSurge" = rollout.maxSurge;
      "rollout.maxUnavailable" = rollout.maxUnavailable;
    }
    // lib.mergeAttrsList (lib.mapAttrsToList (phase: p:
      lib.optionalAttrs (p != null) {
        "probes.${phase}.intervalSeconds" = p.intervalSeconds;
        "probes.${phase}.timeoutSeconds" = p.timeoutSeconds;
        "probes.${phase}.failureThreshold" = p.failureThreshold;
      })
    ir.probes);
  diagnostics =
    map (item: item // {severity = "error";}) imageEligibility.diagnostics
    ++ lib.optional (imageEligibility.supported && builtins.any (id: id > int32Max) userParts)
    (error "KubernetesUserRange" "kubernetes-packaging" "process.user" "UID and GID must fit Kubernetes signed 32-bit identifiers")
    # The controller copies these annotations to ReplicaSets and adds revision
    # history (up to 2000 bytes), the revision and replica counts.
    ++ lib.optional (annotationBytes > 252 * 1024)
    (error "KubernetesAnnotationSize" "kubernetes-packaging" "identity" "identity and manifest digest exceed the 252 KiB Kubernetes annotation budget for Deployments")
    ++ lib.optional (!validNamespace)
    (error "KubernetesInvalidNamespace" "kubernetes-packaging" "kubernetes.namespace" "must be a Kubernetes DNS label")
    ++ lib.optional (createNamespace && namespace == null)
    (error "KubernetesMissingNamespace" "kubernetes-packaging" "kubernetes.namespace" "must be specified when creating a namespace")
    ++ lib.optional (createNamespace && namespace != null && (namespace == "default" || lib.hasPrefix "kube-" namespace))
    (error "KubernetesReservedNamespace" "kubernetes-packaging" "kubernetes.namespace" "namespace creation requires a name outside the built-in namespace family")
    ++ lib.concatLists (lib.mapAttrsToList (field: value:
      lib.optional (value > int32Max)
      (error "KubernetesIntegerOverflow" "kubernetes-packaging" field "must fit a signed Kubernetes 32-bit field"))
    int32Fields)
    ++ lib.optional (isJob && (resources.replicas.min != 1 || resources.replicas.max != 1))
    (error "KubernetesJobReplicaCount" "job-completion" "resources.replicas" "a Job requires a fixed replica count of one")
    ++ lib.optional (!isJob && !resources.strictSingleton && resources.replicas.min <= int32Max && rollout.maxSurge > int32Max - resources.replicas.min)
    (error "KubernetesSurgeOverflow" "rolling-rollout" "rollout.maxSurge" "desired replicas plus surge must fit a signed Kubernetes 32-bit count")
    ++ lib.optional (!isJob && rollout.progressDeadlineSeconds <= rollout.minReadySeconds)
    (error "KubernetesRolloutDeadline" "rollout-deadline" "rollout.progressDeadlineSeconds" "must be greater than rollout.minReadySeconds")
    ++ lib.optional (!isJob && rollout.progressDeadlineSeconds == int32Max)
    (error "KubernetesDisabledDeadline" "rollout-deadline" "rollout.progressDeadlineSeconds" "the maximum signed 32-bit value disables deadline tracking")
    ++ lib.optional (resources.replicas.max != resources.replicas.min)
    (warning "KubernetesReplicaRange" "scaling" "resources.replicas.max" "the Deployment uses the minimum replica count")
    ++ lib.optional (resources.targetMetric != null)
    (warning "KubernetesScalingMetric" "scaling" "resources.targetMetric" "the metric has no native autoscaler mapping")
    ++ lib.optional (resources.placement != [])
    (warning "KubernetesPlacement" "placement" "resources.placement" "opaque placement constraints have no native scheduler mapping")
    ++ lib.optional (!isJob && resources.strictSingleton)
    (warning "KubernetesSingleton" "placement" "resources.strictSingleton" "Recreate avoids overlap during Deployment updates; pod replacement has weaker guarantees")
    ++ lib.optional (isJob && resources.strictSingleton)
    (warning "KubernetesJobSingleton" "placement" "resources.strictSingleton" "singleton admission is consumer policy across Job revisions")
    ++ lib.optional (!isJob)
    (warning "KubernetesDeploymentRestart" "bounded-durable-restart" "restart" (
      if ir.restart.enabled
      then "Deployment restart is Always and uses kubelet retry triggers and timing with no retry limit"
      else "Deployment restart is Always even when Billet restart is disabled"
    ))
    ++ lib.optional (isJob && ir.restart.enabled)
    (warning "KubernetesJobRestart" "bounded-durable-restart" "restart" "the Job maps unexpected-exit retries to backoffLimit; timing and trigger distinctions remain consumer policy")
    ++ lib.optional isJob
    (warning "KubernetesJobRollout" "rolling-rollout" "rollout" "rollout remains consumer policy for a one-shot Job")
    ++ lib.optional (!isJob && rollout.automaticRollback)
    (warning "KubernetesRollback" "bounded-rollback-current-secrets" "rollout.automaticRollback" "the Deployment reports stalled progress and an external consumer owns rollback")
    ++ lib.optional (ir.initialization.steps != [])
    (warning "KubernetesPodInitialization" "initialization-every-start" "initialization.steps" "init containers run on Pod initialization with separate writable root filesystems; container restarts and declared step timeouts are outside this mapping")
    ++ lib.optional (ir.shutdown.stopSignal != "SIGTERM")
    (warning "KubernetesImageStopSignal" "shutdown" "shutdown.stopSignal" "the container runtime must honor the image stop signal")
    ++ lib.optional (ir.shutdown.stopGracePeriodSeconds < 2)
    (warning "KubernetesMinimumShutdownGrace" "shutdown-grace-period" "shutdown.stopGracePeriodSeconds" "kubelet gives the container runtime at least two seconds for shutdown")
    # The default kubelet CRI timeout adds 120 seconds to a signed nanosecond duration.
    ++ lib.optional (ir.shutdown.stopGracePeriodSeconds > 9223372036 - 120)
    (error "KubernetesShutdownDuration" "shutdown-grace-period" "shutdown.stopGracePeriodSeconds" "exceeds the shutdown range with the default kubelet CRI request timeout")
    ++ import ./container-mount-diagnostics.nix {inherit lib;} ir
    ++ lib.mapAttrsToList (direction: _: error "KubernetesBandwidthReservation" "network-bandwidth-reservations" "network.bandwidth.${direction}.minBitsPerSecond" "the Kubernetes workload profile cannot reserve network bandwidth")
    (lib.filterAttrs (_: rates: rates ? minBitsPerSecond) bandwidth)
    ++ lib.concatLists (lib.mapAttrsToList (direction: rate:
      lib.optional (rate < 1000 || rate > 1000000000000000)
      (error "KubernetesBandwidthRange" "network-bandwidth-limits" "network.bandwidth.${direction}.maxBitsPerSecond" "must be in 1000..1000000000000000 bits per second for Kubernetes bandwidth annotations"))
    bandwidthMaxima)
    ++ lib.optional (bandwidthMaxima != {} && !useBandwidthAnnotations)
    (error "KubernetesBandwidthProfile" "network-bandwidth-limits" "kubernetes.bandwidthProfile" "set to pod-annotations to render network bandwidth limits")
    ++ lib.optional (bandwidthMaxima != {} && useBandwidthAnnotations)
    (warning "KubernetesBandwidthCNI" "network-bandwidth-limits" "kubernetes.bandwidthProfile" "enforcement requires a cluster networking plugin configured for Pod bandwidth annotations")
    ++ network.diagnostics
    ++ mounts.diagnostics;
  errors = builtins.filter (item: item.severity == "error") diagnostics;
  capabilityReport = {
    schemaVersion = 1;
    profileVersion = 1;
    rendererVersion = 1;
    target = "kubernetes";
    profile = "kubernetes-artifact-v1";
    mode = "artifact-only";
    inherit (ir) system requiredCapabilities;
    inherit diagnostics;
    manifestDigest = builtins.unsafeDiscardStringContext manifestDigest;
    image = imageEligibility;
    canRender = errors == [];
    supportedCapabilities = lib.optionals (errors == []) (builtins.sort builtins.lessThan (
      ["resources" "shutdown-grace-period"]
      ++ lib.optional isJob "job-completion"
      ++ lib.optionals (!isJob) (["fixed-replicas" "readiness-hold" "rollout-deadline"] ++ lib.optional (!resources.strictSingleton) "rolling-rollout")
      ++ lib.optional (builtins.any (p: p != null) (builtins.attrValues ir.probes)) "probes"
      ++ lib.optional (ir.initialization.steps != []) "pod-initialization"
      ++ lib.optional (bandwidthMaxima != {}) "network-bandwidth-limits"
      ++ network.supportedCapabilities
      ++ mounts.supportedCapabilities
    ));
  };

  # Kubelet expands Kubernetes variable references in exec probes and container
  # commands. The primary process instead inherits literal arguments from OCI.
  escapeDollars = lib.replaceStrings ["$"] ["$$"];
  literal = map escapeDollars;
  env =
    lib.mapAttrsToList (name: value: {
      inherit name;
      value = escapeDollars value;
    })
    (lib.filterAttrs (name: _: isAPIServiceEnv name) ir.process.environment)
    ++ mounts.env;
  probe = p:
    {
      periodSeconds = p.intervalSeconds;
      inherit (p) timeoutSeconds failureThreshold;
    }
    // ({
        exec.exec.command = literal ([p.command.executable] ++ p.command.argv);
        tcp.tcpSocket.port = ir.network.ports.${p.port}.port;
        http.httpGet = {
          inherit (p) path;
          inherit (ir.network.ports.${p.port}) port;
        };
        grpc.grpc.port = ir.network.ports.${p.port}.port;
      }.${
        p.type
      });
  probeFields = lib.mergeAttrsList (lib.mapAttrsToList (phase: p:
    lib.optionalAttrs (p != null) {"${phase}Probe" = probe p;})
  ir.probes);
  container =
    {
      image = oci.reference;
      imagePullPolicy = "IfNotPresent";
      resources = {
        requests = {
          cpu = "${toString resources.cpuRequest}m";
          memory = toString resources.memoryRequest;
        };
        limits = {
          cpu = "${toString resources.cpuLimit}m";
          memory = toString resources.memoryLimit;
        };
      };
    }
    // lib.optionalAttrs (env != []) {inherit env;}
    // lib.optionalAttrs (mounts.volumeMounts != []) {inherit (mounts) volumeMounts;};
  deployment = {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = {inherit name labels annotations;};
    spec = {
      replicas = resources.replicas.min;
      selector.matchLabels = labels;
      inherit (rollout) minReadySeconds progressDeadlineSeconds;
      strategy =
        if resources.strictSingleton
        then {type = "Recreate";}
        else {
          type = "RollingUpdate";
          rollingUpdate = {inherit (rollout) maxSurge maxUnavailable;};
        };
      template = {
        metadata = {
          inherit labels;
          annotations = annotations // bandwidthAnnotations;
        };
        spec =
          {
            enableServiceLinks = false;
            restartPolicy =
              if isJob
              then "Never"
              else "Always";
            terminationGracePeriodSeconds = ir.shutdown.stopGracePeriodSeconds;
            nodeSelector = {
              "kubernetes.io/os" = "linux";
              "kubernetes.io/arch" = imageEligibility.architecture;
            };
            securityContext =
              {
                runAsUser = builtins.head userParts;
                runAsGroup = builtins.elemAt userParts 1;
              }
              # Provisioned volume roots are commonly owned by root.
              // lib.optionalAttrs mounts.hasPersistent {
                fsGroup = builtins.elemAt userParts 1;
                fsGroupChangePolicy = "OnRootMismatch";
              };
            containers = [
              (container
                // {name = "application";}
                // probeFields
                // lib.optionalAttrs (network.ports != []) {inherit (network) ports;})
            ];
          }
          // lib.optionalAttrs overlapsServiceAccountMount {automountServiceAccountToken = false;}
          // lib.optionalAttrs (ir.initialization.steps != []) {
            initContainers = lib.imap0 (index: step:
              container
              // {
                name = "init-${toString index}";
                command = literal [step.executable];
                args = literal step.argv;
              })
            ir.initialization.steps;
          }
          // lib.optionalAttrs (mounts.volumes != []) {inherit (mounts) volumes;};
      };
    };
  };
  jobSpec = {
    completions = 1;
    parallelism = 1;
    backoffLimit = jobRetries;
    inherit (deployment.spec) template;
  };
  job = {
    apiVersion = "batch/v1";
    kind = "Job";
    metadata =
      deployment.metadata
      // {
        name = "${builtins.substring 0 45 name}-job-${builtins.substring 0 12 (hash jobSpec)}";
      };
    spec = jobSpec;
  };
  namespacedResources =
    mounts.claims
    ++ network.items
    ++ [
      (
        if isJob
        then job
        else deployment
      )
    ];
  namespaceResource = lib.optional createNamespace {
    apiVersion = "v1";
    kind = "Namespace";
    metadata.name = namespace;
  };
  requireRenderable = value:
    if capabilityReport.canRender
    then value
    else throw ("billet: UnsupportedTarget kubernetes: " + lib.concatMapStringsSep "; " (item: "${item.field}: ${item.reason}") errors);
  configuration = requireRenderable {
    apiVersion = "v1";
    kind = "List";
    items =
      namespaceResource
      ++ map (item:
        item
        // lib.optionalAttrs (namespace != null) {
          metadata = item.metadata // {inherit namespace;};
        })
      namespacedResources;
  };
  file = requireRenderable (pkgs.writeText "kubernetes.json" (builtins.unsafeDiscardStringContext (builtins.toJSON configuration) + "\n"));
  bundle = requireRenderable (pkgs.runCommand "billet-${identity.name}-kubernetes-v1" {} ''
    mkdir -p "$out"
    cp ${file} "$out/kubernetes.json"
    cp ${oci.archive} "$out/image.tar"
    cp ${billet.manifest} "$out/manifest.json"
  '');
in {inherit configuration file bundle capabilityReport;}
