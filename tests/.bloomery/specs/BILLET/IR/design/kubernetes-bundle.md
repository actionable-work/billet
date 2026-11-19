# Kubernetes application bundles

## Bundle outputs

`mkBilletBundle` exposes `kubernetes.capabilityReport`, `configuration`, `file`,
and `bundle`. Shared structural validation checks member names and systems. The
report includes each member's preflight, member-scoped diagnostics, and the
unions of required and supported capabilities. Any member error prevents
rendering. Preflight and the standalone settings file leave images unrealized.

Render one Kubernetes `v1/List` from the member resources. Use one shared
namespace. If any member selects an explicit namespace, assign it to members
that omitted one. Reject multiple explicit namespaces. Emit the requested
Namespace once before namespaced resources. Reject duplicate namespaced resource
identities. Package the exact List as `kubernetes.json`, an image archive per
member under `images/`, and canonical manifests under `manifests/`.

## One-shot workloads

The `kubernetes.workload` setting defaults to `deployment`. Selecting `job`
renders a `batch/v1` Job with one completion and Pod restart policy `Never`.
Require a fixed replica count of one. A Job's backoff limit uses the declared
retry count when unexpected-exit retries are enabled. In other cases set it to
zero. Keep retry timing and rollout intent in the manifest and report the limits
of the mapping. Derive the Job name from its spec so a changed Job can be
applied alongside a previous completed revision. Preserve the member label and
canonical digest on the Job's Pod template.

## Catalog and report

Render the catalog as a Deployment and Service. The catalog declares private
ingress from the report to its HTTP port. The report uses a Job and requests
`http://catalog:8080/items.json`. Import both archives into a local test
cluster, apply the bundle to one namespace, and assert that the Job completes
and its logs contain the inventory.

## Qualification

`tests/kubernetes-bundle.test.nix` checks report metadata and unions (093–095),
member, namespace, and identity diagnostics (096–098), scope propagation (099),
the Job restart policy and backoff values (100–102), and the revision name
(103). Its standalone JSON check uses a failing application derivation to prove
image independence and counts the Namespace objects (104–105). The K3s guest
compares the three artifact types with their source outputs (106–108) and
verifies the completed Job's inventory (109).
