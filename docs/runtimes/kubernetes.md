# Kubernetes

Each `mkBillet` result exposes a `kubernetes` target for Linux clusters. It
renders an `apps/v1` Deployment with a single application container. Its image
supplies the entrypoint, arguments, ordinary environment, and working directory.

Set `kubernetes.workload = "job"` for a one-shot application. It must declare a
fixed replica count of one. Kubernetes runs the Job to completion with Pod
restart policy `Never`. Its backoff limit comes from enabled unexpected-exit
retries and defaults to zero when those retries are disabled. A changed Job spec
gets a new resource name, so applying a new revision creates a new run.
[Kubernetes Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/job/)

## Build the artifacts

From the [hello example](../../examples/hello) directory, evaluate the report
and build the bundle. Replace the system as needed.

<!-- doctest: kubernetes-build -->

```sh
nix eval --json .#billets.x86_64-linux.hello.kubernetes.capabilityReport
nix build .#billets.x86_64-linux.hello.kubernetes.bundle
```

| Selector           | Result                                                                     |
| ------------------ | -------------------------------------------------------------------------- |
| `capabilityReport` | Preflight errors, mapping advisories, and the IR's required capabilities.  |
| `configuration`    | The Kubernetes `v1/List` as a Nix value.                                   |
| `file`             | `kubernetes.json`, ready for Kubernetes clients. Builds without the image. |
| `bundle`           | `kubernetes.json`, `image.tar`, and the canonical `manifest.json`.         |

The Deployment uses the exact OCI image tag and `IfNotPresent`. Publish the
image at the rendered reference or import `image.tar` on every eligible node.
Set `oci.imageName` to your registry repository before building when publishing
the image. The manifest digest is recorded on the Deployment and Pod template.
[Container image names and pull policy](https://kubernetes.io/docs/concepts/containers/images/)

<!-- doctest: kubernetes-apply -->

```sh
kubectl --namespace my-namespace apply --server-side --dry-run=server --validate=strict -f result/kubernetes.json
kubectl --namespace my-namespace apply --server-side -f result/kubernetes.json
```

## Namespace and other dependencies

With the default settings, use an existing namespace. Set the namespace in the
client context or pass `--namespace` as shown above. To write a namespace
directly into the resources, set it in the Billet module.

<!-- doctest: kubernetes-namespace-module -->

```nix
kubernetes = {
  namespace = "my-namespace";
  createNamespace = true;
};
```

`createNamespace` defaults to `false`. Set it to `true` when the application
should supply a Namespace object. Applying the List creates the opted-in
namespace first. To use an existing namespace, set just `kubernetes.namespace`.
Deleting a Namespace also deletes its contents, so reserve creation for a
namespace this deployment owns. The namespace settings leave the canonical
manifest and OCI image tag unchanged.

When the manifest specifies the namespace, apply the List without a
`--namespace` flag. For a server-side dry run on the first deployment, create
the namespace first. You can apply just the Namespace from the bundle so you can
validate the rest or provision required Secret objects before starting the
Deployment. After adding the settings to the hello module, rebuild the bundle
and apply it in stages.
[Kubernetes namespaces](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/)

<!-- doctest: kubernetes-namespace-apply -->

```sh
nix build .#billets.x86_64-linux.hello.kubernetes.bundle
jq '.items[] | select(.kind == "Namespace")' result/kubernetes.json | kubectl apply --server-side -f -
kubectl apply --server-side --dry-run=server --validate=strict -f result/kubernetes.json
kubectl apply --server-side -f result/kubernetes.json
```

The bundle supplies the Deployment, Services, NetworkPolicy, PVCs and the
opted-in Namespace as applicable. Kubernetes creates ReplicaSets, Pods,
EndpointSlices and the namespace's default ServiceAccount. Supply Secret objects
and referenced storage classes through the cluster, along with image
distribution, a NetworkPolicy-capable CNI and load balancer infrastructure where
used.

## Bundles

`mkBilletBundle` produces one Kubernetes List, `images/<service>.tar`, and
`manifests/<service>.json`. Members share a namespace. An explicit namespace on
one member applies to members that omit it. Resource names and image tags can be
read from `kubernetes.json`.

For the catalog-report example on a single-node K3s cluster, build the bundle
from the repository root, import both images, and apply it into an existing
namespace. The catalog's NetworkPolicy allows the report to reach port 8080
through the catalog Service.

<!-- doctest: kubernetes-bundle -->

```sh
nix build ./examples/catalog-report#billets.x86_64-linux.catalog-report.kubernetes.bundle
for image in result/images/*.tar; do sudo k3s ctr images import "$image"; done
kubectl -n my-namespace apply --server-side -f result/kubernetes.json
report_job=$(jq -r '.items[] | select(.kind == "Job") | .metadata.name' result/kubernetes.json)
kubectl -n my-namespace wait --for=condition=complete "job/$report_job" --timeout=120s
kubectl -n my-namespace logs "job/$report_job"
```

## Workload settings

The renderer explicitly sets any ordinary environment variables whose names
kubelet uses for the Kubernetes API Service, preserving the declared literal
values. Other ordinary environment variables come from the image.

The Deployment starts at the declared minimum replicas, including zero. It uses
the declared CPU and memory requests and limits, numeric user and group, Pod
shutdown grace period, and rolling update settings. Strict singleton uses
`Recreate` for Deployment updates. Replacement outside an update can still
overlap. A custom stop signal uses the OCI image's setting and depends on the
container runtime.
[Deployments](https://kubernetes.io/docs/reference/kubernetes-api/apps/deployment-v1/)
and
[Pod termination](https://kubernetes.io/docs/concepts/workloads/pods/pod-termination/)

Startup, readiness, and liveness probes support exec, TCP, HTTP, and gRPC. The
gRPC application must implement the gRPC health checking protocol. Ordered init
containers use the same image and declared mounts as the application, with
separate writable root filesystems. They complete before the primary container
starts and normally run once per Pod. The canonical manifest retains step
timeouts, initialization on every restart, bounded retries, automatic rollback,
scaling ranges, target metrics, and placement constraints. Deployments use
Kubernetes' `Always` restart policy.
[Kubernetes probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)

## Networking and storage

Declared ports get a ClusterIP Service. Public ports also get a separate
LoadBalancer Service. The cluster supplies the load balancer implementation.
HTTP and gRPC ports use TCP transport. Most application names appear directly as
Service DNS names. Names outside the Kubernetes naming profile use a stable
generated name. Read the generated Service metadata for its exact DNS name. The
identity `kubernetes` also uses a generated name to avoid targeting the API
Service.

The NetworkPolicy allows ingress to public ports and from the same-namespace
Pods named by declared private links. Declare a link on the destination Billet
for ingress. With `publicEgress = false` on the source, declare the link there
as well to allow egress to the named destination port. Egress isolation blocks
DNS unless the cluster adds an allow policy. Network policies are additive and
require support from the cluster's CNI, including named egress ports when used.
Opaque `egressRestrictions` stay in the canonical manifest with an advisory.
Single-Billet preflight can validate the local destination port and protocol.
Checking both rendered resources verifies that selectors and ports agree. Live
reachability additionally depends on the cluster's policies, networking, DNS and
the destination's readiness.
[NetworkPolicy behavior](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

Set `kubernetes.bandwidthProfile = "pod-annotations"` to render declared
bandwidth maxima on Deployment and Job Pod templates. This profile accepts
maximums of 1,000 through 1,000,000,000,000,000 bits per second. Verify that the
cluster's networking plugin enforces the Pod bandwidth annotations on the paths
your workload uses before deploying. The Kubernetes API can accept the
annotations even when cluster enforcement is unavailable. Preflight rejects a
minimum because this profile cannot reserve network capacity. The canonical
manifest remains available for a consumer that supports reservations.
[Kubernetes traffic shaping](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/#support-traffic-shaping)

Ephemeral claims use `emptyDir` with the declared size limit, backed by memory
or node disk. Disk size enforcement depends on kubelet accounting. A persistent
disk claim becomes one PVC shared by the application's replicas, with the
requested storage class, access mode, and size. The Pod then sets `fsGroup` to
the declared GID so the application user can write to a volume whose root is
owned by another user. The cluster needs a matching provisioner and storage
compatible with the replica topology, and the volume type must support ownership
management.

## Provide secrets

Use `external = "<secret-name>/<key>"` for a key in an existing Kubernetes
Secret. An optional environment reference leaves its variable unset when the key
is missing. A required file reference mounts only that key at the exact declared
path. Optional file targets fail preflight because the projection cannot
reliably leave that path absent. Replace the Pod to refresh environment or file
values.
[Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)
