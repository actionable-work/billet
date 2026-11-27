# Container consumer boundaries

## Protected mount targets

Compose and Kubernetes preflight each declared storage mount and file secret
before rendering. Reject a destination at, below, or above `/nix/store`,
`/etc/billet/manifest.json`, or `/etc/billet/closure.json` on a path component
boundary. OCI images use the store namespace for their immutable closure and
those files for artifact metadata. Protect the entire store namespace because
the closure can include transitive references unavailable during preflight.
Unrelated names such as `/nix/storehouse` and other files in `/etc/billet`
remain available. Environment references do not mount paths. Diagnostics name
`storage.<claim>.mountPoint` or `secrets.<reference>.target` without including
the configured target. Report all conflicts, including member prefixes in bundle
reports. The portable manifest and image remain independently available. Source
lineage is BI003, BI004, BI006 and BI011.

## Known bundle destinations

Compose and Kubernetes bundles resolve the destination service of each member's
private connection in the bundle when present. If present, require its declared
port name to exist and its protocol to equal the connection's protocol. Report
missing ports at `destinationPort` and a protocol mismatch at `protocol`, on
`services.<declaring member>.network.privateConnections.<index>`. The index
follows canonical IR order. Errors block configuration, standalone file and
packaged bundle selection before mapping connections. A link to a service
outside the bundle remains eligible under existing target behavior. Source
lineage is BI004 and BI011.

## Kubernetes termination grace

Keep the declared grace in eligible Job and Deployment Pod templates. Warn at
`shutdown.stopGracePeriodSeconds` for zero or one second because the qualified
kubelet gives the runtime at least two seconds for container shutdown. Refuse
values above 9223371916 seconds on the same field. At the upper end, the
qualified CRI uses signed 64-bit nanoseconds and the default kubelet CRI stop
request adds 120 seconds to the requested grace. The renderer uses that default
as headroom for the upper bound. A cluster with a longer CRI request timeout has
a lower effective limit. Source lineage is BI004, BI011 and BI016.

## Compose CPU limits

Reject `resources.cpuLimit` above 9223371264000 millicores in Compose preflight.
This is the last whole-millicore declaration whose decimal core value rounds to
a float32 that the pinned Compose can multiply by one billion and convert to
positive signed 64-bit nanocores. Qualify the upper bound at the Engine request
boundary with the actual pinned Compose consumer. The bound concerns numeric
representability. A real Engine still checks host capacity. Keep the portable
value and the existing CPU reservation advisory. Source lineage is BI004, BI011
and BI012.

## Qualification

The protected-mount test uses independent storage and file-secret fixtures for
each target and checks all artifact selectors in both single and bundle form. It
also checks portable artifact selection, value-free diagnostics, and a separate
valid fixture for unrelated paths. The bundle-link test checks both diagnostic
fields in canonical order and uses separate matching and external fixtures. The
grace test checks warning presence and exact Pod template values independently
in Jobs and Deployments and refuses the first out-of-range value. The Compose
CPU test refuses the first unrepresentable value and checks the ceiling in a
separate pinned-consumer Engine create request to an isolated test endpoint.
