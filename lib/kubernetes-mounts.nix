{
  lib,
  ir,
  hash,
  warning,
  error,
  isAPIServiceEnv,
}: let
  dnsSubdomain = value:
    builtins.stringLength value
    <= 253
    && builtins.match "[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*" value != null;
  secretKey = value:
    builtins.stringLength value
    <= 253
    && builtins.match "[-._a-zA-Z0-9]+" value != null
    && value != "."
    && !lib.hasPrefix ".." value;
  secrets = lib.mapAttrs (logical: secret: let
    parts = lib.splitString "/" secret.external;
    valid = builtins.length parts == 2 && dnsSubdomain (builtins.head parts) && secretKey (builtins.elemAt parts 1);
  in
    secret
    // {
      inherit valid;
      ref = {
        name = builtins.head parts;
        key = builtins.elemAt parts 1;
        optional = !secret.required;
      };
      volumeName = "secret-${builtins.substring 0 56 (hash logical)}";
    })
  ir.secrets;
  fileSecrets = builtins.filter (secret: secret.mode == "file") (builtins.attrValues secrets);
  environmentSecrets = builtins.filter (secret: secret.mode == "environment") (builtins.attrValues secrets);
  storage = lib.mapAttrs (logical: claim:
    claim
    // {
      volumeName = "volume-${builtins.substring 0 56 (hash logical)}";
      claimName = "billet-pvc-${builtins.substring 0 52 (hash [ir.identity.name logical])}";
      readOnly = claim.accessMode == "readOnlyMany";
      accessMode =
        {
          readWriteOnce = "ReadWriteOnce";
          readOnlyMany = "ReadOnlyMany";
          readWriteMany = "ReadWriteMany";
        }.${
          claim.accessMode
        };
    })
  ir.storage;
  persistent = builtins.filter (claim: claim.lifecycle == "persistent") (builtins.attrValues storage);
in {
  hasPersistent = persistent != [];
  env =
    map (secret: {
      name = secret.target;
      valueFrom.secretKeyRef = secret.ref;
    })
    environmentSecrets;
  volumes =
    map (secret: {
      name = secret.volumeName;
      secret = {
        secretName = secret.ref.name;
        defaultMode = 292; # 0444
        items = [
          {
            inherit (secret.ref) key;
            path = "value";
          }
        ];
      };
    })
    fileSecrets
    ++ map (claim:
      {
        name = claim.volumeName;
      }
      // (
        if claim.lifecycle == "persistent"
        then {
          persistentVolumeClaim = {
            inherit (claim) claimName readOnly;
          };
        }
        else {
          emptyDir =
            {sizeLimit = toString claim.sizeBytes;}
            // lib.optionalAttrs (claim.medium == "memory") {medium = "Memory";};
        }
      )) (builtins.attrValues storage);
  volumeMounts =
    map (secret: {
      name = secret.volumeName;
      mountPath = secret.target;
      subPath = "value";
      readOnly = true;
    })
    fileSecrets
    ++ map (claim: {
      name = claim.volumeName;
      mountPath = claim.mountPoint;
      inherit (claim) readOnly;
    }) (builtins.attrValues storage);
  claims =
    map (claim: {
      apiVersion = "v1";
      kind = "PersistentVolumeClaim";
      metadata.name = claim.claimName;
      spec = {
        accessModes = [claim.accessMode];
        storageClassName = claim.driverClass;
        resources.requests.storage = toString claim.sizeBytes;
      };
    })
    persistent;
  supportedCapabilities =
    lib.optional (secrets != {}) "runtime-secrets"
    ++ lib.unique (map (claim: "storage-${claim.lifecycle}-${claim.medium}") (builtins.attrValues storage));
  diagnostics =
    lib.concatLists (lib.mapAttrsToList (logical: secret:
      lib.optional (!secret.valid)
      (error "KubernetesSecretReference" "runtime-secrets" "secrets.${logical}.external" "must be a Kubernetes Secret name and key separated by a slash")
      ++ lib.optional (secret.mode == "file" && !secret.required)
      (error "KubernetesOptionalSecretFile" "runtime-secrets" "secrets.${logical}.required" "optional file delivery cannot reliably leave the exact mount path absent")
      ++ lib.optional (secret.mode == "environment" && !secret.required && isAPIServiceEnv secret.target)
      (error "KubernetesOptionalSecretEnvironment" "runtime-secrets" "secrets.${logical}.target" "kubelet can supply this API Service variable when the Secret key is absent"))
    secrets)
    ++ lib.concatLists (lib.mapAttrsToList (logical: claim:
      lib.optional (claim.lifecycle == "persistent" && !dnsSubdomain claim.driverClass)
      (error "KubernetesStorageClass" "storage-persistent-disk" "storage.${logical}.driverClass" "must be a Kubernetes StorageClass name")
      ++ lib.optional (claim.lifecycle == "ephemeral")
      (warning "KubernetesEmptyDirClass" "storage-${claim.lifecycle}-${claim.medium}" "storage.${logical}.driverClass" "emptyDir uses node storage without a provisioner class or access topology")
      ++ lib.optional (claim.lifecycle == "ephemeral" && claim.medium == "disk")
      (warning "KubernetesEmptyDirAccounting" "storage-ephemeral-disk" "storage.${logical}.sizeBytes" "disk emptyDir size enforcement depends on kubelet storage accounting"))
    storage);
}
