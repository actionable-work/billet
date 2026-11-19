# Canonical Billet IR v1

Billet describes one application. The public API is
`lib.mkBillet { pkgs; modules; }`. Modules are evaluated with `lib.evalModules`;
`pkgs` is a special argument. The result exposes `ir`, `canonicalJSON`,
`manifestDigest`, `manifest`, `closureDescriptor`, and `runtimeRoots`. Flakes
expose `billets.<system>.<name>`. All module code and non-secret literals are
trusted public build inputs. Nix is not a secret-handling sandbox: never read
credentials or pass secret values to Nix. The secret schema accepts only
metadata, and Billet never resolves it.

## Encoding and identity

`schemaVersion = 1` and `normalizationVersion = 1`. Reject all other schema
versions; migration must be explicit. Canonical bytes are UTF-8
`builtins.toJSON` with lexicographically ordered object keys, no whitespace and
no trailing newline. Numbers are integers (CPU in millicores, memory/storage in
bytes, time in seconds; restart multiplier is an integer greater than one). No
timestamps, derivations, source locations or evaluator metadata enter IR.
SHA-256 over these exact bytes is `sha256:<lowercase hex>`. The digest is
outside its own payload. Maps represent named ports, secrets and storage;
semantically unordered string lists normalize to sorted unique arrays. `argv`,
initialization and command-probe arrays retain order, empty strings and
metacharacters. Renderers must never join argv into shell. Schema v1 is unfrozen
until Billet's first release, so fields and defaults may change within it. After
that release, changing defaults or encoding requires a version change and
migration note.

## Module fields

Unknown fields and wrong types fail with a field path and a reason that does not
echo the supplied value. Required fields have no implicit application defaults.
Names/IDs use `[a-zA-Z0-9][a-zA-Z0-9_.-]*`; environment names use shell
identifier syntax. Store packages must be derivations for the selected `pkgs`
system.

| Field                  | Contract and defaults                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `schemaVersion`        | Integer 1.                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `identity`             | Required `name`, `version` nonempty strings.                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `systems`              | Nonempty list of allowed system strings, default selected `pkgs` system; selected system must be included. Standalone interface is generic.                                                                                                                                                                                                                                                                                                                                          |
| `process`              | Exactly one record: required derivation `package`, package-relative `executable` (no absolute path or `..`/`.` segments), `argv=[]`, non-secret `environment={}`, absolute normalized `workingDirectory="/"`, `user="65534:65534"`. IR records package output store path and absolute executable.                                                                                                                                                                                    |
| `initialization`       | `steps=[]`, each with unique `id`, process package/executable/argv and positive `timeoutSeconds`; `budgetSeconds=0` for empty steps, otherwise required positive, at least sum of step timeouts and no greater than `startupAllowanceSeconds=30`. Each launch must rerun all steps; no runtime work occurs at evaluation/build.                                                                                                                                                      |
| `resources`            | Required positive `cpuRequest`, `cpuLimit`, `memoryRequest`, `memoryLimit`, requests <= limits. `replicas={ min=1; max=1; }`, nonnegative bounds min <= max. `targetMetric=null` or a nonempty string; `placement=[]`, `strictSingleton=false`. Singleton disallows max > 1 or positive rollout surge.                                                                                                                                                                               |
| `probes`               | `startup`, `readiness`, `liveness` default null. Probe `type` is `exec`, `tcp`, `http` or `grpc`; `command` is a package/executable/argv record for exec, otherwise null; `port` references a named network port for other types, otherwise null; `path="/"` (HTTP), `intervalSeconds=10`, `timeoutSeconds=1`, `failureThreshold=3`, all positive, timeout <= interval. Startup allowance belongs to initialization above.                                                           |
| `restart`              | `enabled=true`, triggers unexpected-exit/liveness-failure/startup-failure, `maxRetries=5`, `initialDelaySeconds=1`, `maxDelaySeconds=30`, `multiplier=2`, `jitter=true`, `continuousReadyResetSeconds=300`. Retry count finite/nonnegative, delays/reset positive, cap >= initial delay. Normalize explicit effective policy. Full restart policy includes durable per-replica accounting, positive bounded jitter, and exhaustion.                                                  |
| `shutdown`             | `stopSignal="SIGTERM"`, `stopGracePeriodSeconds=30` nonnegative; portable signal vocabulary SIGTERM/SIGINT/SIGQUIT/SIGHUP; final SIGKILL and whole-tree reaping are mandatory. Target supports or rejects signal.                                                                                                                                                                                                                                                                    |
| `rollout`              | `strategy="rolling"`, `maxSurge=1`, `maxUnavailable=0`, `minReadySeconds=10`, `progressDeadlineSeconds=600`, `automaticRollback=true`. Counts/hold nonnegative, deadline positive, at least one progress allowance, unavailable <= nonzero minimum replica count. Runtime counts include reservations and stopping replicas. One bounded rollback restores exact non-secret config with current authorized secret bindings.                                                          |
| `network`              | `ports={}`: each has required integer `port` 1..65535, `protocol="tcp"` (`tcp`/`http`/`grpc`), `exposure="private"` (`private`/`public`). `privateConnections=[]` records required `sourceService`, `destinationService`, `destinationPort`, protocol; these request directional policy, never grant authority. `publicEgress=true`, `egressRestrictions=[]` nonempty strings; policy-required capabilities follow restrictions. Hosted parent restrictions belong to admission.     |
| `secrets`              | Named map: required nonempty `external`, `mode="file"` (`file`/`environment`), required `target` absolute normalized path or environment variable, `required=true`. No value field or arbitrary provider object. Reject duplicate delivery targets, collisions with non-secret environment, and file/mount collisions. Resolve only at runtime through current authorized bindings.                                                                                                  |
| `storage`              | Named map: required absolute normalized `mountPoint`, `lifecycle="ephemeral"` (`ephemeral`/`persistent`), `medium="disk"` (`disk`/`memory`), required positive `sizeBytes`, `accessMode="readWriteOnce"` (`readWriteOnce`/`readOnlyMany`/`readWriteMany`), required nonempty `driverClass`. Reject root/overlapping mounts, duplicate mounts, persistent memory and total memory scratch exceeding memoryLimit. Full storage semantics include hard bounds, cleanup, and durability. |
| `requiredCapabilities` | Sorted unique strings; unioned with automatically derived lifecycle, probes, secrets, resources, networking, storage and scaling capabilities. They are requirements, never a conformance claim.                                                                                                                                                                                                                                                                                     |

No application-list, supervisor or guest-module escape hatch exists. Workers may
be children of the primary and share its lifecycle/resources. An application
wrapper cannot turn independent applications into one supported Billet.

## OCI packaging options

`oci.imageName` names the image repository. It accepts lowercase path components
separated by `/` (`[a-z0-9]+` joined by `.`, `_`, `__` or `-`), optionally after
a registry host such as `registry.example.com:5000`, with a maximum length of
255 characters. A missing image name defaults to the lowercase `identity.name`.
The v1 IR records the effective repository as `oci.imageName`. The `identity`
record contains the application name and version.

`oci.maxLayers` accepts an integer from 1 through 124. The resolved setting is
passed to the [OCI adapter](../../CLOSURE/design/oci.md#runtime-layers) as a
packaging option outside the canonical application IR. Validation identifies
invalid values by their OCI option paths.

The former `docker.maxLayers` module option supplies the default for
`oci.maxLayers`. The layer-budget check compares image derivations and
references across both spellings and verifies precedence for an explicit
`oci.maxLayers` value.

## Validation and runtime boundary

Validation is deterministic and fails before producing artifacts on unknown
fields, unsupported schema, invalid executable syntax, duplicate IDs/ports,
conflicting mounts/delivery targets, missing probe ports, bad budgets/resources,
invalid policies or excluded systems. Executable _existence and execute bits_
are checked when building the closure descriptor, after packages are realized.
That includes initialization and exec probes. Entrypoints must resolve inside
their declared package output; runtime dependencies belong to that output
closure. A valid IR is input to target-specific artifact rendering. Renderers
preserve policy declarations for the consuming runtime and report unsupported
artifact inputs with field paths before build. Credential resolution,
application supervision and lifecycle decisions belong to the runtime. The
[target contract](targets.md) specifies which fields each artifact expresses
natively and how it reports limitations.
