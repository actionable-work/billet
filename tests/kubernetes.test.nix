{
  pkgs,
  billetLib,
}: let
  inherit (pkgs) lib;
  fixtures = import ./fixtures.nix {inherit pkgs billetLib;};
  make = extra: fixtures.evaluate (lib.recursiveUpdate fixtures.base extra);
  trap = pkgs.runCommand "billet-kubernetes-must-not-build" {} "exit 99";
  privateLink = {
    sourceService = "Source.App";
    destinationService = "Kube.Example";
    destinationPort = "grpc";
    protocol = "grpc";
  };
  state = {
    lifecycle = "persistent";
    mountPoint = "/state";
    sizeBytes = 16384;
    driverClass = "team.fast";
    accessMode = "readOnlyMany";
  };
  full = {
    identity = {
      name = "Kube.Example";
      version = "build/1";
    };
    oci.imageName = "example.com/team/app";
    requiredCapabilities = ["site-admission"];
    process = {
      package = trap;
      executable = "bin/trap";
      user = "1001:1002";
    };
    resources = {
      replicas = {
        min = 0;
        max = 3;
      };
      cpuRequest = 125;
      cpuLimit = 625;
      memoryRequest = 18000000;
      memoryLimit = 50000000;
      targetMetric = "latency";
      placement = ["somewhere"];
    };
    restart.enabled = false;
    shutdown = {
      stopSignal = "SIGQUIT";
      stopGracePeriodSeconds = 9;
    };
    rollout = {
      maxSurge = 2;
      maxUnavailable = 1;
      minReadySeconds = 4;
      progressDeadlineSeconds = 19;
    };
    initialization = {
      budgetSeconds = 4;
      steps = [
        {
          id = "write";
          package = trap;
          executable = "bin/trap";
          argv = ["$(LITERAL)"];
          timeoutSeconds = 2;
        }
        {
          id = "check";
          package = trap;
          executable = "bin/check";
          argv = [];
          timeoutSeconds = 2;
        }
      ];
    };
    probes = {
      readiness = {
        intervalSeconds = 3;
        timeoutSeconds = 2;
        failureThreshold = 4;
        command = {
          package = trap;
          executable = "bin/check";
          argv = ["" "$(LITERAL)" "a; b"];
        };
      };
      startup = {
        type = "grpc";
        port = "grpc";
      };
      liveness = {
        type = "http";
        port = "web";
        path = "/live";
      };
    };
    network = {
      ports = {
        web = {
          port = 8080;
          protocol = "http";
          exposure = "public";
        };
        grpc = {
          port = 9000;
          protocol = "grpc";
        };
      };
      privateConnections = [privateLink (privateLink // {destinationPort = "missing";})];
      publicEgress = false;
      egressRestrictions = ["operator-defined"];
    };
    secrets = {
      file = {
        external = "team.runtime/DB_PASSWORD";
        target = "/run/keys/db";
      };
      env = {
        external = "runtime/token";
        target = "TOKEN";
        mode = "environment";
      };
      optional = {
        external = "runtime/optional";
        target = "OPTIONAL";
        mode = "environment";
        required = false;
      };
    };
    storage = {
      inherit state;
      memory = {
        medium = "memory";
        mountPoint = "/memory";
        sizeBytes = 4096;
        driverClass = "tmpfs";
      };
      disk = {
        mountPoint = "/disk";
        sizeBytes = 8192;
        driverClass = "local";
      };
    };
  };
  app = make full;
  source = make {
    identity.name = "Source.App";
    oci.imageName = "example.com/team/source";
    network = {
      publicEgress = false;
      privateConnections = [privateLink];
    };
  };
  singleton = make {
    resources.strictSingleton = true;
    rollout = {
      maxSurge = 0;
      maxUnavailable = 1;
    };
  };
  report = app.kubernetes.capabilityReport;
  namespaced = make (lib.recursiveUpdate full {kubernetes.namespace = "workloads";});
  configuration = app.kubernetes.configuration;
  items = artifact: artifact.kubernetes.configuration.items;
  resourcesOf = kind: builtins.filter (item: item.kind == kind);
  one = kind: artifact: lib.findSingle (_: true) null null (resourcesOf kind (items artifact));
  deployment = one "Deployment" app;
  pod = deployment.spec.template.spec;
  container = builtins.head pod.containers;
  probeName = p: builtins.head (builtins.filter (port: port.containerPort == p) container.ports);
  portName = (probeName 9000).name;
  services = resourcesOf "Service" configuration.items;
  service = type: lib.findSingle (item: item.spec.type == type) null null services;
  policy = (one "NetworkPolicy" app).spec;
  pvc = one "PersistentVolumeClaim" app;
  mount = path: lib.findSingle (item: item.mountPath == path) null null container.volumeMounts;
  volume = path: lib.findSingle (item: item.name == (mount path).name) null null pod.volumes;
  env = name: (lib.findSingle (item: item.name == name) null null container.env).valueFrom.secretKeyRef;
  annotation = key: deployment.metadata.annotations."billet.actionable.work/${key}";
  warnAt = code: field: builtins.any (item: item.severity == "warning" && item.code == code && item.field == field) report.diagnostics;
  rejected = overrides: code: field: let
    target = (make overrides).kubernetes;
  in
    !target.capabilityReport.canRender
    && target.capabilityReport.supportedCapabilities == []
    && builtins.any (item: item.severity == "error" && item.code == code && item.field == field) target.capabilityReport.diagnostics
    && !(builtins.tryEval target.configuration).success
    && !(builtins.tryEval target.file.drvPath).success
    && !(builtins.tryEval target.bundle.drvPath).success;
  min = value: {
    resources.replicas = {
      min = value;
      max = value;
    };
  };
  headers = configuration.apiVersion == "v1" && configuration.kind == "List";
  check = name: {
    passthru,
    assertions,
  }: let
    ids = builtins.attrNames assertions;
  in
    assert passthru.bloomery == map (id: "BILLET-IR-KUBERNETES-${id}") ids;
      pkgs.runCommand "billet-kubernetes-${name}" {
        inherit passthru;
        validations = map (id: assert lib.assertMsg assertions.${id} "Kubernetes requirement ${id} failed"; "1") ids;
      } ''touch "$out"'';
in {
  "billet:kubernetes-preflight" = check "preflight" {
    passthru.bloomery = [
      "BILLET-IR-KUBERNETES-001"
      "BILLET-IR-KUBERNETES-003"
      "BILLET-IR-KUBERNETES-009"
      "BILLET-IR-KUBERNETES-016"
      "BILLET-IR-KUBERNETES-017"
      "BILLET-IR-KUBERNETES-018"
      "BILLET-IR-KUBERNETES-023"
      "BILLET-IR-KUBERNETES-024"
      "BILLET-IR-KUBERNETES-025"
      "BILLET-IR-KUBERNETES-027"
      "BILLET-IR-KUBERNETES-028"
      "BILLET-IR-KUBERNETES-029"
      "BILLET-IR-KUBERNETES-030"
      "BILLET-IR-KUBERNETES-038"
      "BILLET-IR-KUBERNETES-039"
      "BILLET-IR-KUBERNETES-045"
      "BILLET-IR-KUBERNETES-050"
      "BILLET-IR-KUBERNETES-051"
      "BILLET-IR-KUBERNETES-052"
      "BILLET-IR-KUBERNETES-053"
      "BILLET-IR-KUBERNETES-054"
      "BILLET-IR-KUBERNETES-064"
      "BILLET-IR-KUBERNETES-069"
      "BILLET-IR-KUBERNETES-072"
      "BILLET-IR-KUBERNETES-076"
      "BILLET-IR-KUBERNETES-077"
      "BILLET-IR-KUBERNETES-079"
      "BILLET-IR-KUBERNETES-082"
      "BILLET-IR-KUBERNETES-085"
      "BILLET-IR-KUBERNETES-086"
      "BILLET-IR-KUBERNETES-087"
    ];
    assertions = {
      "001" =
        report.schemaVersion
        == 1
        && report.profileVersion == 1
        && report.rendererVersion == 1
        && report.profile == "kubernetes-artifact-v1"
        && report.target == "kubernetes"
        && report.mode == "artifact-only";
      "003" =
        report.requiredCapabilities
        == app.ir.requiredCapabilities
        && builtins.elem "site-admission" report.requiredCapabilities
        && !(builtins.elem "site-admission" report.supportedCapabilities);
      "009" = rejected {process.user = "invalid";} "UnsupportedImageUser" "process.user";
      "016" = warnAt "KubernetesReplicaRange" "resources.replicas.max";
      "017" = warnAt "KubernetesScalingMetric" "resources.targetMetric";
      "018" = warnAt "KubernetesPlacement" "resources.placement";
      "023" = rejected {
        rollout = {
          minReadySeconds = 4;
          progressDeadlineSeconds = 4;
        };
      } "KubernetesRolloutDeadline" "rollout.progressDeadlineSeconds";
      "024" =
        rejected (min 2147483648) "KubernetesIntegerOverflow" "resources.replicas.min"
        && rejected {
          probes.readiness.intervalSeconds = 2147483648;
          probes.readiness.type = "tcp";
          network.ports.web.port = 80;
          probes.readiness.port = "web";
        } "KubernetesIntegerOverflow" "probes.readiness.intervalSeconds";
      "025" = rejected (min 2147483647) "KubernetesSurgeOverflow" "rollout.maxSurge";
      "027" =
        pod.restartPolicy
        == "Always"
        && warnAt "KubernetesDeploymentRestart" "restart"
        && !(builtins.elem "bounded-durable-restart" report.supportedCapabilities);
      "028" = warnAt "KubernetesRollback" "rollout.automaticRollback";
      "029" =
        warnAt "KubernetesPodInitialization" "initialization.steps"
        && !(builtins.elem "initialization-every-start" report.supportedCapabilities);
      "030" = warnAt "KubernetesImageStopSignal" "shutdown.stopSignal";
      "038" =
        rejected {
          secrets.wrong = {
            external = "DO-NOT-ECHO-SECRET";
            target = "/wrong";
          };
        } "KubernetesSecretReference" "secrets.wrong.external"
        && !(lib.hasInfix "DO-NOT-ECHO-SECRET" (builtins.toJSON
          (make {
            secrets.wrong = {
              external = "DO-NOT-ECHO-SECRET";
              target = "/wrong";
            };
          }).kubernetes.capabilityReport));
      "039" = rejected {
        secrets.optional = {
          external = "valid/key";
          target = "/optional";
          required = false;
        };
      } "KubernetesOptionalSecretFile" "secrets.optional.required";
      "045" = rejected {storage.state = state // {driverClass = "Invalid_Class";};} "KubernetesStorageClass" "storage.state.driverClass";
      "050" = warnAt "KubernetesEgressDNS" "network.publicEgress";
      "051" = warnAt "KubernetesEgressRestrictions" "network.egressRestrictions";
      "052" =
        builtins.any (item: item.code == "KubernetesPrivateConnectionPort") report.diagnostics
        && builtins.length policy.ingress == 2;
      "053" = report.canRender && report.image.supported && builtins.elem "probes" report.supportedCapabilities && headers;
      "069" =
        !(builtins.elem "KubernetesEgressDNS" (map (item: item.code) (make {}).kubernetes.capabilityReport.diagnostics))
        && resourcesOf "NetworkPolicy" (items (make {})) == [];
      "054" = warnAt "KubernetesEmptyDirClass" "storage.memory.driverClass";
      "064" = warnAt "KubernetesEmptyDirAccounting" "storage.disk.sizeBytes";
      "072" = rejected {rollout.progressDeadlineSeconds = 2147483647;} "KubernetesDisabledDeadline" "rollout.progressDeadlineSeconds";
      "076" =
        rejected {process.user = "2147483648:1002";} "KubernetesUserRange" "process.user"
        && rejected {process.user = "1001:2147483648";} "KubernetesUserRange" "process.user"
        && (make {process.user = "2147483647:2147483647";}).kubernetes.capabilityReport.canRender;
      "077" = rejected {
        identity.version = lib.foldl' (value: _: value + value) "x" (lib.range 1 19);
      } "KubernetesAnnotationSize" "identity";
      "079" = builtins.all (target:
        rejected {
          secrets.optional = {
            external = "runtime/optional";
            mode = "environment";
            required = false;
            inherit target;
          };
        } "KubernetesOptionalSecretEnvironment" "secrets.optional.target") [
        "KUBERNETES_SERVICE_HOST"
        "KUBERNETES_SERVICE_PORT"
        "KUBERNETES_SERVICE_PORT_HTTPS"
        "KUBERNETES_PORT"
        "KUBERNETES_PORT_443_TCP_ADDR"
      ];
      "082" = let
        sample = make {identity.version = "x";};
        metadata = (one "Deployment" sample).metadata;
        fixedBytes =
          lib.foldlAttrs (size: key: value:
            size + builtins.stringLength key + builtins.stringLength value)
          (-1)
          metadata.annotations;
        version = length: builtins.substring 0 length (lib.foldl' (value: _: value + value) "x" (lib.range 1 18));
        allowed = 252 * 1024 - fixedBytes;
      in
        (make {identity.version = version allowed;}).kubernetes.capabilityReport.canRender
        && rejected {identity.version = version (allowed + 1);} "KubernetesAnnotationSize" "identity";
      "085" = rejected {kubernetes.createNamespace = true;} "KubernetesMissingNamespace" "kubernetes.namespace";
      "086" = builtins.all (namespace:
        rejected {kubernetes = {inherit namespace;};}
        "KubernetesInvalidNamespace" "kubernetes.namespace") ["" "work.team" "Bad_Name" "-work"];
      "087" = builtins.all (namespace:
        rejected {
          kubernetes = {
            inherit namespace;
            createNamespace = true;
          };
        }
        "KubernetesReservedNamespace" "kubernetes.namespace") ["default" "kube-system" "kube-custom"];
    };
  };

  "billet:kubernetes-workload" = check "workload" {
    passthru.bloomery = [
      "BILLET-IR-KUBERNETES-006"
      "BILLET-IR-KUBERNETES-008"
      "BILLET-IR-KUBERNETES-010"
      "BILLET-IR-KUBERNETES-011"
      "BILLET-IR-KUBERNETES-012"
      "BILLET-IR-KUBERNETES-013"
      "BILLET-IR-KUBERNETES-014"
      "BILLET-IR-KUBERNETES-015"
      "BILLET-IR-KUBERNETES-019"
      "BILLET-IR-KUBERNETES-020"
      "BILLET-IR-KUBERNETES-021"
      "BILLET-IR-KUBERNETES-022"
      "BILLET-IR-KUBERNETES-026"
      "BILLET-IR-KUBERNETES-031"
      "BILLET-IR-KUBERNETES-032"
      "BILLET-IR-KUBERNETES-033"
      "BILLET-IR-KUBERNETES-034"
      "BILLET-IR-KUBERNETES-035"
      "BILLET-IR-KUBERNETES-065"
      "BILLET-IR-KUBERNETES-066"
      "BILLET-IR-KUBERNETES-070"
      "BILLET-IR-KUBERNETES-071"
      "BILLET-IR-KUBERNETES-073"
    ];
    assertions = {
      "006" =
        annotation "identity-name"
        == app.ir.identity.name
        && annotation "identity-version" == app.ir.identity.version
        && annotation "manifest-digest" == app.manifestDigest
        && deployment.metadata.annotations == deployment.spec.template.metadata.annotations;
      "008" =
        pod.nodeSelector
        == {
          "kubernetes.io/arch" = report.image.architecture;
          "kubernetes.io/os" = "linux";
        };
      "010" = let
        next = one "Deployment" (make (lib.recursiveUpdate full {identity.version = "build/2";}));
        simple = one "Deployment" (make {});
        reserved = one "Deployment" (make {identity.name = deployment.metadata.name;});
      in
        lib.hasPrefix "billet-x-" deployment.metadata.name
        && builtins.stringLength deployment.metadata.name <= 63
        && next.metadata.name == deployment.metadata.name
        && next.spec.selector == deployment.spec.selector
        && deployment.spec.selector.matchLabels == deployment.spec.template.metadata.labels
        && simple.metadata.name == "hello"
        && reserved.metadata.name != deployment.metadata.name;
      "011" = container.resources.requests.cpu == "125m";
      "012" = container.resources.limits.cpu == "625m";
      "013" = container.resources.requests.memory == "18000000";
      "014" = container.resources.limits.memory == "50000000";
      "015" =
        deployment.spec.replicas
        == 0
        && (one "Deployment" (make (min 2))).spec.replicas == 2;
      "070" =
        container.image
        == app.ociImage.imageRefUnsafe
        && container.imagePullPolicy == "IfNotPresent"
        && !(container ? command)
        && !(container ? args)
        && !(container ? workingDir);
      "071" = pod.securityContext.runAsUser == 1001 && pod.securityContext.runAsGroup == 1002;
      "019" = deployment.spec.strategy.type == "RollingUpdate" && deployment.spec.strategy.rollingUpdate.maxSurge == 2;
      "020" = deployment.spec.strategy.rollingUpdate.maxUnavailable == 1;
      "021" = deployment.spec.minReadySeconds == 4;
      "022" = deployment.spec.progressDeadlineSeconds == 19;
      "026" =
        (one "Deployment" singleton).spec.strategy
        == {type = "Recreate";}
        && builtins.any (item: item.code == "KubernetesSingleton") singleton.kubernetes.capabilityReport.diagnostics;
      "031" = container.startupProbe.grpc == {port = 9000;};
      "073" = let
        initNamedApp = make (lib.recursiveUpdate full {identity.name = "init-0";});
        spec = (one "Deployment" initNamedApp).spec.template.spec;
      in
        map (item: item.name) (spec.containers ++ spec.initContainers) == ["application" "init-0" "init-1"];
      "032" = container.readinessProbe.exec.command == ["${trap}/bin/check" "" "$$(LITERAL)" "a; b"];
      "033" =
        container.livenessProbe.httpGet
        == {
          port = 8080;
          path = "/live";
        };
      "034" = container.readinessProbe.periodSeconds == 3;
      "065" = container.readinessProbe.timeoutSeconds == 2;
      "066" = container.readinessProbe.failureThreshold == 4;
      "035" =
        map (step: {inherit (step) command args;}) pod.initContainers
        == [
          {
            command = ["${trap}/bin/trap"];
            args = ["$$(LITERAL)"];
          }
          {
            command = ["${trap}/bin/check"];
            args = [];
          }
        ]
        && builtins.all (step:
          step.image
          == container.image
          && step.volumeMounts == container.volumeMounts
          && step.env == container.env
          && step.resources == container.resources)
        pod.initContainers;
    };
  };

  "billet:kubernetes-mounts" = check "mounts" {
    passthru.bloomery = [
      "BILLET-IR-KUBERNETES-036"
      "BILLET-IR-KUBERNETES-037"
      "BILLET-IR-KUBERNETES-040"
      "BILLET-IR-KUBERNETES-041"
      "BILLET-IR-KUBERNETES-042"
      "BILLET-IR-KUBERNETES-043"
      "BILLET-IR-KUBERNETES-044"
      "BILLET-IR-KUBERNETES-067"
      "BILLET-IR-KUBERNETES-068"
      "BILLET-IR-KUBERNETES-110"
      "BILLET-IR-KUBERNETES-111"
    ];
    assertions = {
      "036" =
        env "TOKEN"
        == {
          name = "runtime";
          key = "token";
          optional = false;
        };
      "037" =
        env "OPTIONAL"
        == {
          name = "runtime";
          key = "optional";
          optional = true;
        };
      "040" =
        (volume "/run/keys/db").secret
        == {
          secretName = "team.runtime";
          defaultMode = 292;
          items = [
            {
              key = "DB_PASSWORD";
              path = "value";
            }
          ];
        }
        && (mount "/run/keys/db").subPath == "value"
        && (mount "/run/keys/db").readOnly
        && resourcesOf "Secret" configuration.items == [];
      "041" =
        (volume "/memory").emptyDir
        == {
          medium = "Memory";
          sizeLimit = "4096";
        };
      "042" = (volume "/disk").emptyDir == {sizeLimit = "8192";};
      "043" = pvc.spec.storageClassName == "team.fast";
      "067" = pvc.spec.resources.requests.storage == "16384";
      "068" =
        (volume "/state").persistentVolumeClaim.claimName
        == pvc.metadata.name
        && (one "PersistentVolumeClaim" (make (lib.recursiveUpdate full {identity.version = "build/2";}))).metadata.name == pvc.metadata.name;
      "044" =
        pvc.spec.accessModes
        == ["ReadOnlyMany"]
        && (volume "/state").persistentVolumeClaim.readOnly
        && (mount "/state").readOnly;
      "110" = pod.securityContext.fsGroup == 1002 && pod.securityContext.fsGroupChangePolicy == "OnRootMismatch";
      "111" = let
        context = (one "Deployment" (make {})).spec.template.spec.securityContext;
      in
        !(context ? fsGroup) && !(context ? fsGroupChangePolicy);
    };
  };

  "billet:kubernetes-network" = check "network" {
    passthru.bloomery = [
      "BILLET-IR-KUBERNETES-046"
      "BILLET-IR-KUBERNETES-047"
      "BILLET-IR-KUBERNETES-048"
      "BILLET-IR-KUBERNETES-049"
      "BILLET-IR-KUBERNETES-080"
    ];
    assertions = {
      "046" =
        (service "ClusterIP").metadata.name
        == deployment.metadata.name
        && (service "ClusterIP").spec.selector == deployment.spec.selector.matchLabels
        && map (p: p.port) (service "ClusterIP").spec.ports == [9000 8080]
        && builtins.all (p: p.protocol == "TCP" && p.targetPort == (probeName p.port).name) (service "ClusterIP").spec.ports;
      "047" =
        map (p: p.port) (service "LoadBalancer").spec.ports
        == [8080]
        && (service "LoadBalancer").metadata.name != (service "ClusterIP").metadata.name;
      "048" =
        policy.ingress
        == [
          {
            ports = [
              {
                port = 8080;
                protocol = "TCP";
              }
            ];
          }
          {
            from = [{podSelector.matchLabels = (one "Deployment" source).spec.selector.matchLabels;}];
            ports = [
              {
                port = 9000;
                protocol = "TCP";
              }
            ];
          }
        ]
        && policy.podSelector.matchLabels == deployment.spec.selector.matchLabels;
      "049" =
        policy.policyTypes
        == ["Ingress" "Egress"]
        && policy.egress == []
        && (one "NetworkPolicy" source).spec.egress
        == [
          {
            to = [{podSelector.matchLabels = deployment.spec.selector.matchLabels;}];
            ports = [
              {
                port = portName;
                protocol = "TCP";
              }
            ];
          }
        ];
      "080" = let
        reserved = make {
          identity.name = "kubernetes";
          network.ports.api.port = 443;
        };
        reservedService = one "Service" reserved;
        reservedDeployment = one "Deployment" reserved;
      in
        lib.hasPrefix "billet-x-" reservedService.metadata.name
        && reservedService.metadata.name == reservedDeployment.metadata.name
        && reservedService.spec.selector == reservedDeployment.spec.selector.matchLabels
        && reservedDeployment.metadata.annotations."billet.actionable.work/identity-name" == "kubernetes";
    };
  };

  "billet:kubernetes-namespace" = check "namespace" {
    passthru.bloomery = [
      "BILLET-IR-KUBERNETES-083"
      "BILLET-IR-KUBERNETES-088"
      "BILLET-IR-KUBERNETES-089"
    ];
    assertions = {
      "083" =
        map (item: item.kind) (items namespaced)
        == ["PersistentVolumeClaim" "Service" "Service" "NetworkPolicy" "Deployment"]
        && builtins.all (item: item.metadata.namespace == "workloads") (items namespaced)
        && !((one "Deployment" namespaced).spec.template.metadata ? namespace)
        && (one "Deployment" (make {kubernetes.namespace = "default";})).metadata.namespace == "default";
      "088" = builtins.all (item: item.kind != "Namespace" && !(item.metadata ? namespace)) (items app);
      "089" =
        namespaced.canonicalJSON
        == app.canonicalJSON
        && namespaced.manifestDigest == app.manifestDigest
        && namespaced.ociImage.imageRefUnsafe == app.ociImage.imageRefUnsafe;
    };
  };

  "billet:kubernetes-file" =
    pkgs.runCommand "billet-kubernetes-file" {
      passthru.bloomery = ["BILLET-IR-KUBERNETES-002"];
      file = app.kubernetes.file;
      expected = builtins.unsafeDiscardStringContext (builtins.toJSON configuration);
    } ''
      test "$(cat "$file")" = "$expected"
      touch "$out"
    '';
}
