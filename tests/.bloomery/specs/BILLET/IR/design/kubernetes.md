# Kubernetes artifact profile v1

The [bundle design](kubernetes-bundle.md) specifies the multi-member artifact
and the one-shot Job profile.

## Public artifacts

`mkBillet` exposes `kubernetes.configuration` as a core `v1/List`, `file` as
`kubernetes.json`, and `bundle` as a directory with that file, the existing
Docker-loadable `image.tar`, and exact canonical `manifest.json`. The file and
configuration can be produced without realizing any application dependency.
`capabilityReport` identifies `kubernetes-artifact-v1`, reports OCI preflight
and field-scoped renderer diagnostics, and distinguishes native mappings from
the IR's unchanged `requiredCapabilities`. Errors prevent rendering; warnings
permit it. Each Billet is rendered independently.

The Deployment and its Pod template carry the original Billet name, version, and
canonical manifest digest in annotations. The image also carries the canonical
manifest. Resource and selector names use the identity itself when it is a
letter-led lowercase DNS label up to 63 characters and avoids the reserved
prefixes `billet-x-` and `billet-public-` and the API Service name `kubernetes`.
Other names use `billet-x-` plus a stable hash of the original identity. The
public Service uses its own reserved hash-based name. Selectors remain stable
when the definition changes. Reject identity metadata that exceeds 252 KiB. This
leaves 4 KiB for controller annotations including revision, replica counts and
revision history when the Deployment annotations are copied to ReplicaSets.

## Namespace and dependencies

The optional module setting `kubernetes.namespace` is a Kubernetes DNS-label
namespace name. When supplied, set `metadata.namespace` on every namespaced
resource. Otherwise the Kubernetes client selects the namespace. With
`kubernetes.createNamespace = true`, prepend a single cluster-scoped Namespace
resource to the List. Creation requires an explicit namespace and rejects
`default` and the reserved `kube-` prefix. The settings only affect Kubernetes
artifacts and preflight. Canonical IR and OCI identity remain portable.

The bundle supplies the application's Deployment, Services, NetworkPolicy and
PVCs when applicable. Kubernetes controllers supply ReplicaSets, Pods,
EndpointSlices and the default ServiceAccount. The cluster supplies Secret
objects and values, image distribution, CNI, load balancer infrastructure and
persistent disk provisioning.

## Workload and lifecycle

Render one `apps/v1` Deployment with one application container using the exact
OCI tag and `IfNotPresent`. It inherits the image entrypoint, argv, ordinary
environment, working directory, and image stop signal. The Pod records numeric
UID/GID, the image OS and architecture as node selectors, and the shutdown grace
period. An ordinary environment value with a name that kubelet derives from the
API Service is also included in Pod `env`, with Kubernetes dollar escaping so it
reaches the app and init containers literally. Other ordinary values are
inherited from the image. Reject UID or GID values beyond the Kubernetes signed
32-bit range. Non-default stop signals depend on the container runtime honoring
the OCI setting; report that limitation.

Set replicas to the declared minimum, including zero. Apply CPU requests and
limits in millicores and memory in bytes. A range, metric, and opaque placement
constraints each have their own advisory. Map rolling surge, unavailable count,
ready hold, and progress deadline. A strict singleton uses Recreate to avoid
overlap during Deployment updates and reports the limit on singleton guarantees
during replacement. Automatic rollback is a manifest-only policy. Deployment
restart policy is Always. Report the mismatch with declared restart triggers,
bounds and timings, including a disabled restart policy.

Map startup, readiness, and liveness independently. Exec probes use a literal
command array, including Kubernetes dollar escaping. TCP, HTTP, and gRPC use the
referenced numeric port; HTTP also carries its path. Render interval, timeout
and failure threshold. Reject values outside the native signed 32-bit fields, a
rollout deadline not greater than the ready hold, and the maximum signed 32-bit
deadline value that disables deadline tracking.

Render declared initialization steps as ordered Pod init containers with the
same image, resources, declared volumes, and secret references as the
application. Each supplies its own literal command and argv. Init container
names use an index and the application container has a separate name. Report the
difference between Pod initialization and initialization on every container
restart, the separate writable root filesystem, and the absence of step and
aggregate time enforcement.

## Services and policy

A ClusterIP Service provides DNS for all declared TCP transport ports. A
separate LoadBalancer Service carries only publicly exposed ports. HTTP and gRPC
use TCP transport. NetworkPolicy allows ingress to public ports and otherwise
only from matching same-namespace source Pods named by declared links to a valid
local destination port. Pod identity labels and stable named container ports
allow separately rendered applications to refer to each other. Port names use a
stable letter-led name derived from logical name and protocol so the same target
port is used by both ends of an egress rule.

With public egress disabled, isolate egress and allow only declared links from
the local application to same-namespace destination Pods on the named port.
Rules on both endpoints must allow the flow where both are isolated. The profile
does not infer DNS infrastructure. Report that DNS needs an external policy for
egress-isolated Pods, and report opaque restrictions which have no translation.
Diagnose invalid local link ports or protocol mismatches. The policy requires
CNI enforcement and remains subject to namespace admission and other additive
policies. The renderer does not manage a load balancer.

## Secret references and storage

For this profile, interpret `external` as a same-namespace `<name>/<key>`
Kubernetes Secret reference. Validate reference shape before rendering. Use
`secretKeyRef` with the declared optionality for environment delivery. For a
required file, project only the selected key, then mount it read-only with
`subPath` at the exact target. The one-file volume is readable by the
application's image user. Reject optional file delivery because an absent key
cannot reliably be represented as an absent path with this mount mechanism.
Reject optional environment targets that match API Service variables because
kubelet can supply the variable when the Secret key is absent. If any declared
mount overlaps the automatic ServiceAccount token mount, disable token
automounting for that Pod so the declared mount can be used. Mounted file
references and environment references are sampled at startup. Do not emit Secret
objects or resolve secret values.

Use `emptyDir` with `sizeLimit` for ephemeral claims and select memory backing
for memory claims. Report that emptyDir has no storage class or access topology,
and that disk size enforcement depends on kubelet accounting. For persistent
disk, emit a stable, uniquely named PersistentVolumeClaim with the declared
storage class, access mode and byte request. All replicas reference that same
claim. Mount at the declared path and set the mount read-only for ReadOnlyMany.
When any persistent claim is declared, set the Pod `fsGroup` to the numeric GID
with the `OnRootMismatch` change policy so the image user can write to a newly
provisioned volume whose root is owned by another user. Reject storage class
names that are invalid for PVCs.

## Qualification

The pure artifact checks qualify resource identity, payloads, preflight and
canonical references, including a fixture whose process package cannot build. An
isolated single-node K3s test validates the generated List through the
Kubernetes API and runs the bundled image with real kubelet, Service, and Secret
consumers. The K3s test also renders both sides of a private link and verifies
actual traffic from an egress-isolated Billet to the destination. Tests bind
individual requirements to their assertions.

The K3s test also renders two versions of one Billet that differ in
`identity.version`, argv and image tag. It applies the first List, then the
second over it with strict server-side validation. Billet qualifies only the
artifacts and their acceptance by the consumer. The API server accepts the
update, the updated Deployment carries the declared rolling strategy, ready hold
and progress deadline, and the rollout completes with only second-version Pods
ready. Kubernetes owns how and when the rollout proceeds.

The numbers below refer to `BILLET-IR-KUBERNETES` records. The pure checks in
`tests/kubernetes.test.nix` evaluate a separately keyed assertion for each
binding. The VM checks in `tests/kubernetes-vm.test.nix` use the native API
server and kubelet.

| Records                                                                   | Witness                                                                                                                                                                                                                                             |
| ------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 001, 003, 009, 016–018, 023–025, 027–030, 038–039, 045, 050–054, 064, 069 | Versioned report, unchanged capabilities, field-scoped denial and redaction, successful warning-only preflight, and scoped mapping advisories. Rejected fixtures exercise configuration, file and bundle selectors.                                 |
| 002                                                                       | Build the standalone file from the unrealizable package fixture and compare it with the pure configuration.                                                                                                                                         |
| 006, 008, 010–015, 019–022, 026, 031–035, 065–066, 070–071                | Deployment and Pod assertions cover provenance, stable names and selectors, architecture, resources, replica counts, rollout, probes, ordered init containers, image inheritance and numeric user.                                                  |
| 036–037, 040–044, 067–068, 110–111                                        | Environment and file reference payloads, projected key, exact mount, emptyDir backing and size, PVC request, stable claim, read-only access and volume group ownership.                                                                             |
| 046–049                                                                   | ClusterIP target ports, public-only LoadBalancer ports, the precise ingress and egress rule payloads, and cross-output selector and named port agreement.                                                                                           |
| 004–005, 007                                                              | Byte comparisons of the packaged workload file, canonical manifest and Docker archive.                                                                                                                                                              |
| 055                                                                       | Strict server-side dry run of the bundled workload.                                                                                                                                                                                                 |
| 056–059                                                                   | Import the archive and wait for the Deployment to become available. The app checks argv, environment, working directory and numeric identity. Both init exits, their shared output and the startup and readiness results witness kubelet execution. |
| 060                                                                       | Read the application response through the generated ClusterIP.                                                                                                                                                                                      |
| 061–062                                                                   | The process compares the file and environment Secret values and checks optional absence. Live mount data verifies the read-only secret file and the memory volume size.                                                                             |
| 063                                                                       | Inspect the admitted Pod's termination grace period.                                                                                                                                                                                                |
| 072–073                                                                   | Reject the reserved progress deadline and render distinct container names for a Billet named `init-0`.                                                                                                                                              |
| 074–075                                                                   | Run the denial assertion inside the peer Pod and require the exec command to succeed. The named peer reaches the private port and the other Pod reaches the public port.                                                                            |
| 076–077                                                                   | OCI-eligible UID and GID boundary fixtures and an oversized identity annotation fail Kubernetes preflight.                                                                                                                                          |
| 078, 081, 084, 090                                                        | The live process checks a literal API Service environment override and a required Secret on another injected name. The VM checks delivery under the default token path and applies the List into a namespace created by the List itself.            |
| 079–080, 082–083, 085–089                                                 | Pure evaluation checks optional environment rejection, API Service naming, the exact annotation budget, namespace validation and render modes, and unchanged canonical and image metadata.                                                          |
| 091–092                                                                   | A separately rendered, egress-isolated Billet reaches its declared private port through the destination Service and cannot reach that same destination on an undeclared port.                                                                       |
| 112–114                                                                   | The second List applies over the first. The updated Deployment has the declared strategy, ready hold and progress deadline, and its ready Pods run the second image with the second version annotation and argv.                                    |
