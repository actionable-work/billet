# Per-replica network bandwidth reservations and limits

## Canonical policy

Each direction may declare a minimum, a maximum, or both.

```nix
network.bandwidth = {
  ingress = {
    minBitsPerSecond = 100000000;
    maxBitsPerSecond = 500000000;
  };
  egress = {
    minBitsPerSecond = 50000000;
    maxBitsPerSecond = 200000000;
  };
};
```

Each field accepts a positive integer in decimal bits per second or `null`, and
all four default to `null`. Reject a minimum above the maximum in the same
direction at the `minBitsPerSecond` field. Allow equality. Ingress arrives at
the workload and egress leaves it. Each rate applies to the aggregate traffic in
its direction at one replica's network boundary, across connections and
interfaces. Loopback within a replica is outside that boundary. Each admitted
replica, including a rollout surge replica, receives its own rates.

A minimum requires a reservation of schedulable network capacity and the ability
to deliver at least that sustained rate to eligible, backlogged traffic under
contention within the runtime's declared and qualified network domain. Eligible
traffic follows the workload's existing routing and access policy. The runtime
publishes the domain, packet accounting, and sustained measurement window.
Sender and receiver availability, congestion outside that domain, and
application processing can all limit observed goodput. A maximum caps the
sustained rate, with burst behavior and packet accounting defined by the runtime
profile. Idle reserved capacity may be borrowed and must be reclaimable under
contention. A replica may use spare capacity up to its maximum when one is
declared. Bandwidth policy confers no network access or port exposure.

Omit unset fields, empty directions, and an empty `network.bandwidth` from the
canonical JSON. Omitted and explicit `null` rates are equivalent. Existing v1
manifests without rates retain their bytes and digest. Derive
`network-bandwidth-reservations` when any minimum is set and
`network-bandwidth-limits` when any maximum is set. A definition with both
requires both capabilities. The manifest carries application intent. Hosted
policy can supply additional limits or reservations. After resolving the
effective policy, reject an effective maximum below a requested minimum.
Service-wide or tenant-wide quotas and billable transfer belong to the runtime.
Source lineage is BI001, BI002, BI004, BI010 and BI012.

## Hammerworks minimum bandwidth

### Admission and placement

Lineshaft needs separate ingress and egress reservation budgets for the managed
bottlenecks in a placement's qualified network domain. Budget usable capacity
with headroom for platform traffic and measured overhead. A host NIC's
advertised link speed alone cannot establish capacity for a path with a shared
uplink or fabric segment. A deployable profile identifies the schedulers and
capacity pools for paths it covers, and admission must account for shared pools.
Reserve all relevant capacity before enabling traffic. If the profile cannot
enforce a requested minimum, report an unsupported capability. If a qualified
profile has insufficient available capacity, use the existing
`WaitingForCapacity` behavior.

Charge reservations by replica incarnation through the existing rollout and
placement lifecycle. Overlapping generations and surge replicas consume their
own capacity. Concurrent admissions must respect the same budget. Retain a
reservation while the old replica can still use it, including uncertain cleanup,
and release it once the dataplane is confirmed fenced or cleaned up. If usable
capacity falls below committed reservations, report degraded enforcement and
block admissions that would consume the affected capacity until it can be
reconciled. Preserve the requested minimum in status. Source lineage is BI004,
BI011, BI012 and BI017.

### Dataplane and coverage

For a managed, shared outbound queue, evaluate a classful scheduler such as
Linux HTB, with one class per replica and an admitted parent budget. Its `rate`
and `ceil` match the two different controls. A queue on an individual TAP can
cap that replica, while a scheduler at the shared bottleneck arbitrates it
against other replicas. A per-TAP shaper alone cannot reserve an oversubscribed
uplink. Account for same-host switching, cross-host fabric and edge paths
wherever they are eligible under the chosen profile. Traffic on multiple
interfaces shares the replica's directional budget.

For an ingress minimum, reserve and schedule traffic on the sending side of
managed bottlenecks or use a fabric service that already provides the
reservation. A receive-side queue or policer operates after upstream contention.
Public traffic can receive a commitment inside the Hammerworks network from a
managed edge only when the edge-to-replica path is qualified. Public internet
links upstream of that edge are outside the commitment.

Qualify managed private egress first on a deliberately bounded network profile.
A placement with other eligible managed paths needs coverage for those paths
before it can claim the same capability. Qualify ingress separately with
competing senders, and then extend to edge traffic when the managed edge and
fabric can participate. Apply the effective profile before application traffic
starts and every time a replica is replaced.
[HTB class rates and ceilings](https://man7.org/linux/man-pages/man8/tc-htb.8.html)
·
[OpenStack placement and dataplane QoS](https://docs.openstack.org/neutron/2026.2/admin/config-qos.html)

### Maximum bandwidth

Lineshaft selects Cloud Hypervisor under DR106. Its virtio-net limiter applies
the same configured rate to separate receive and transmit buckets per queue
pair. This can express a symmetric maximum for a qualified single-NIC,
single-queue profile. Independent limits and a shared multiqueue budget need a
limiter at a common network boundary. Use the shared scheduler's ceiling where
it covers the full requested direction. Qualify a separate shaper when there is
no reservation or traffic paths require a different enforcement point.
[Cloud Hypervisor throttling](https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/io_throttling.md)
·
[virtio-net queue implementation](https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/virtio-devices/src/net.rs)

## Kubernetes workload mapping

Use `kubernetes.bandwidthProfile = "pod-annotations"` as an explicit renderer
setting for a maximum. Render each maximum as an exact decimal string in
`kubernetes.io/ingress-bandwidth` or `kubernetes.io/egress-bandwidth` on the
Deployment or Job Pod template. Use the initial renderer range of 1,000 through
1,000,000,000,000,000 bits per second inclusive from containerd's parser. Reject
out-of-range maxima at the corresponding field. Emit a preflight warning naming
the dependency on a configured bandwidth-capable CNI and leave enforcement
verification to deployment. The capability report describes native projection.

Reject a requested minimum for the standard Kubernetes workload profile with a
field-specific diagnostic, even if an accompanying maximum could be rendered.
The Pod bandwidth annotations express only maxima. An extended resource could
account for reservations at the scheduler. A qualified reservation profile would
also need a dataplane scheduler and accounting for any shared network paths.
Keep the canonical manifest available to external consumers. Source lineage is
BI004 and BI011.
[Kubernetes annotations](https://kubernetes.io/docs/reference/labels-annotations-taints/#kubernetes-io-ingress-bandwidth)
·
[containerd parser](https://github.com/containerd/containerd/blob/main/internal/cri/bandwidth/utils.go)
· [CNI bandwidth plugin](https://www.cni.dev/plugins/current/meta/bandwidth/) ·
[Kubernetes extended resources](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#extended-resources)

## Consumer-managed networking

The OCI image, Compose bundles and Nix microVM bundles preserve all requested
rates in their canonical manifests. Stock Compose and Nix microVM preflight
report each requested bound as a field-specific consumer-managed limitation and
omit the corresponding capability from their native mapping lists. Artifact
eligibility permits packaging for a qualified external consumer. The consumer
must enforce required bounds or refuse admission. Source lineage is BI004 and
BI011.

Docker and Compose operators can shape traffic at the Linux container network
boundary. Consumers of Nix microVM can provision a TAP for host-side shaping.
Billet's stock standalone guest has no virtual NIC, and connected bundles use
QEMU user-mode networking. Both integrations need scheduling at shared
bottlenecks and capacity admission to support minimums. Consider native mappings
only for consumer profiles that can qualify the relevant routes and directions.
[Docker bridge networking](https://docs.docker.com/engine/network/drivers/bridge/)
·
[MicroVM.nix network interfaces](https://microvm-nix.github.io/microvm.nix/interfaces.html#type--tap)

## Qualification

Billet's executable checks witness canonical omission and stable v1 identity,
each rate's validation and preservation, per-direction ordering, capability
derivation, each target's supported or unsupported mapping, and packaged
manifests. Run the Kubernetes maximum profile against a pinned Linux cluster
with an uncapped baseline and concurrent flows. Measure sustained rates after
bursts over direct IPv4/TCP Pod traffic from same-node and cross-node peers and
from a host outside the cluster with a route to the target node's Pod CIDR. Keep
live throughput results separate from manifest and annotation assertions.

| `BILLET-IR-BANDWIDTH` records | Witness                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 001–006, 036–037, 039         | `billet:bandwidth-ir` compares the canonical bytes and digest for implicit and explicit defaults, checks omission of empty directions and bounds, and asserts round-trip rates and capabilities for minimum-only, maximum-only, and combined declarations. Its combined fixture has equal egress rates.                                                                                                                                                 |
| 007–009                       | `billet:rejection-diagnostics` checks the exact field and reason for a non-integer minimum and maximum, zero and negative rates, and an inverted range in each direction.                                                                                                                                                                                                                                                                               |
| 010–018, 035, 038             | `billet:bandwidth-kubernetes` asserts profile and field errors, both annotation range boundaries, placement on Deployment and Job templates, omission of the unset direction, the CNI advisory, advertised mapping, and service-scoped bundle rejection.                                                                                                                                                                                                |
| 019–022, 040–043              | `billet:bandwidth-consumer-reports` checks render eligibility, required and supported capabilities, and every direction and bound's warning on standalone and bundle reports.                                                                                                                                                                                                                                                                           |
| 023–028                       | `billet:bandwidth-manifests` compares the exact canonical bytes in the Docker archive, standalone and project Compose bundles, standalone and project microVM bundles, and Kubernetes project bundle.                                                                                                                                                                                                                                                   |
| 029–034                       | `billet:kubernetes-bandwidth-live` consumes the rendered Deployment in an isolated, two-node K3s cluster with the CNI `bandwidth` plugin. Six subtests measure ingress and egress over direct IPv4/TCP paths to Pod addresses from same-node, cross-node, and outside-cluster peers. Each verifies delivery on all three simultaneous flows, measures an uncapped control, and samples the capped rate after the estimated token bucket burst interval. |

The Lineshaft consumer qualifies the reservation contract with simultaneous
backlogged replicas under shared-link saturation, best-effort borrowing when a
reserved replica goes idle, and reclamation when it resumes. Check each
supported direction and prove a replica's aggregate maximum with concurrent
flows. Test that over-capacity and concurrent placement requests cannot
oversubscribe a pool, that an exhausted surge preserves the old allocation, and
that uncertain teardown holds the reservation. Exercise loss of a managed path
or of available capacity. Report enforcement only for paths the deployment
profile has qualified.
