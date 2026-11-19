# Target artifact boundary

Billet produces target artifacts from canonical Nix IR. Docker, Compose,
Kubernetes, Nix microVM and Hammerworks-native are separate renderer families. A
consuming runtime owns application execution and all lifecycle policy. Required
capabilities remain part of the canonical IR even when a native artifact
consumer ignores that metadata.

## Docker image

The existing pinned nix2container image and OCI layout retain their application
closure, primary process configuration and identity. Export that same image to a
Docker-loadable archive using its exact content-derived image reference. The
archive build operates without a Docker daemon.

## Compose artifact

Render one application service keyed by the IR identity name. Reference the
exact exported image, `identity.imageName` with its content-derived tag, and
require a locally loaded image with pull policy `never`. Compose inherits the
entrypoint, argv, ordinary environment, user, and working directory from the
image. Native Compose directives project the applicable policy fields. A
top-level `x-billet` extension gives the configured runtime the canonical
manifest's relative path and exact digest. Write the Compose document as JSON, a
YAML subset accepted by the pinned Compose consumer.

Provide the configuration as a pure Nix value, the standalone Compose file, and
a bundle directory containing `compose.yaml`, `image.tar`, and `manifest.json`.
The bundle contains the canonical IR bytes including policy declarations and
reference-only secret metadata.

TARGETS-011 originally covered the absence of any Compose lifecycle override.
The native mappings below supersede that part of the requirement. TARGETS-011
continues to protect the image's primary process configuration.

### Compose resources and replicas

Render CPU limits and requests as decimal cores with exact millicore precision.
Render memory limits and requests as decimal byte strings. Use
`deploy.resources.limits` for limits and `deploy.resources.reservations` for
requests. Standalone Docker Compose applies the memory reservation. Report CPU
reservation as a limitation of the standalone consumer while retaining it in the
Compose file. Set `deploy.replicas` to the declared minimum, including zero. A
range starts at its minimum and reports that the maximum is only preserved in
the manifest. `targetMetric`, placement and strict singleton remain manifest
policies.

### Compose lifecycle

Render `stop_signal` and `stop_grace_period` from shutdown settings. Render
`restart: on-failure:N` for enabled unexpected-exit retries with a positive
limit. Exit code zero ends the container. Disabled restart, zero retries, or a
policy without unexpected-exit uses `restart: "no"`. Startup- and
liveness-failure restart triggers, backoff, jitter, the ready-reset window and
rollout remain manifest policies.

Use the first executable health probe in readiness, liveness order. Render the
absolute executable and literal argv as a `CMD` array with Docker Compose dollar
escaping. Render its interval, timeout and failure threshold as `interval`,
`timeout` and `retries`. Set `start_period` to the startup probe interval times
its failure threshold, or to the initialization startup allowance when absent.
Cap the start period at the upper bound of the Compose duration range and report
an advisory when the calculated value exceeds that bound. The start period
approximates startup timing. A startup probe command is preserved in the
manifest. Emit an advisory for each TCP, HTTP or gRPC probe because the image
does not supply a network probe client. Emit an advisory when initialization
steps are present because Compose one-shot services would run with a different
filesystem and start lifecycle. A liveness healthcheck reports health for
operators and cannot trigger restart.

### Compose networking

Publish public TCP transport ports using Compose-assigned host port numbers,
which allow repeated container ports across services and replicas. HTTP and gRPC
use TCP transport. Use `expose` for private ports. If any service disables
public egress, attach all services to an internal project network and attach
egress-enabled services to a second non-internal network with gateway priority.
Services on the internal network alone keep port metadata in `expose` and report
the public port publishing limitation of the standalone engine. When all members
allow egress, retain the default Compose network. Directional rules and egress
restrictions stay in the manifest.

### Compose secrets

Derive Compose secret keys and host environment identifiers from the
case-preserved member and logical secret names. Escape hyphen, dot and
underscore in each component as `_H`, `_D` and `_U`, respectively, then join the
components with `__`. Host variables prepend `BILLET_SECRET_` to this key. Use a
top-level environment-sourced Compose secret for file delivery. Map it to the
declared absolute target with owner-only read permission for the image user.
Compose requires the host variable to be set for file sources and skips the file
for an empty value. Report this limitation for optional file references. A
required environment target uses required, nonempty interpolation. An optional
environment target uses an empty default. Resolve all values in Compose and
preserve the external reference in the manifest.

### Compose storage

Use sized tmpfs mounts for ephemeral memory and anonymous local volumes for
ephemeral disk. Use separately named project volumes for persistent disk, with
collision-free keys derived from the member and claim as for secrets. Use the
declared mount point for all mounts and a read-only mount for `readOnlyMany`.
Driver class and access topology stay in the manifest. Local volumes have no
enforced size limit. Diagnose the missing disk quota.

### Multi-service bundles

`lib.mkBilletBundle { pkgs; billets; }` accepts a nonempty attrset of already
evaluated Billets on the selected package-set system. Each key must match its
Billet's canonical application identity. The bundle exposes its members under
`billets` and uses the same `dockerCompose` output selectors as `mkBillet`. Its
preflight includes each member's report, the unions of required and supported
capabilities, and service-scoped diagnostics. An invalid bundle or member
prevents rendering before any image is built.

Merge the member services, secret definitions and volume definitions into one
Compose file, with network membership calculated across the project. Combine
`privateConnections` declarations from all members into startup ordering edges.
For links between distinct members that name a declared destination port, make
the source wait via `depends_on: service_healthy` if the destination renders an
exec readiness healthcheck and has at least one replica. Omit edges that would
participate in a cycle and report affected sources. This ordering neither grants
nor enforces network access. Package each image under `images/<service>.tar` and
its canonical IR under `manifests/<service>.json`. The bundle's
`x-billet.services` extension records the relative manifest path and digest for
each service.

### Multi-service example

The `billets.<system>.catalog-report` example uses this bundle interface. The
catalog serves JSON on the Compose network. The report fetches it by service
name and exits. The example uses native Compose service discovery and requires
no published host port. Verify that each archived image and manifest matches its
service and that the report receives the JSON in the Docker VM.

### Example subflakes

Each example owns its `billets` output and supports direct builds from its
directory. The hello subflake consumes Billet directly and exports an app that
uses its Billet's selected executable. The catalog-report subflake uses
Bloomery's `billets` callback to expose both services and their Compose bundle.
It passes the Rust workspace's exported `catalog` package as the primary process
package. The report fetches inventory from the Rust catalog in Compose.

## Artifact preflight

The versioned capability report measures artifact eligibility. It echoes the
IR-required capabilities for the consumer and lists supported native Compose
mappings for the rendered configuration. The supported list does not establish
conformance to the full IR capabilities. Image diagnostics for unsupported
systems or users prevent rendering. Field-scoped mapping limitations have
`severity = "warning"` and allow rendering. Evaluating a supported configuration
or report does not realize the application package.

## Qualification

Verify the pure configuration against an unrealizable fixture, including image
reference, one service, preserved required capabilities, and redacted field
diagnostics. In an automated isolated Linux VM, load the exported archive,
validate the rendered configuration with the pinned Compose CLI, and run the
declared primary process through that Compose file. Assert exact canonical
manifest bytes and verify that no lifecycle controller or credential value is
added to the artifacts.

The same VM qualifies native directives against the pinned Compose CLI and
engine. Compare parsed resources and container limits, counts, shutdown and
restart settings. Check exact healthcheck argv and scheduling settings, live
readiness ordering, service DNS and internal/external network membership,
published reachability, and host-supplied file and environment data. Inspect
container mounts and distinguish pure configuration evidence for unsupported
features from live Docker behavior.

The assertions in `tests/compose.test.nix` bind the following witnesses. Each
number refers to a `BILLET-IR-TARGETS` record.

| Records      | Witness                                                                                                                                                                                                        |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 026–029, 083 | Parsed limit and reservation units, live CPU and memory limits and memory reservation, and the CPU reservation advisory.                                                                                       |
| 030–032      | Parsed fixed counts of one and zero, a parsed and running minimum of two for a range, and the range advisory.                                                                                                  |
| 033–039      | Engine stop signal and timeout, an exhausted two-retry container, no-restart for zero retries, disabled or unmatched triggers, and a clean exit with no restart.                                               |
| 040–046      | Live readiness command with literal argv, parsed liveness fallback, and selected interval, timeout, retries and both start-period sources.                                                                     |
| 047–049      | Distinct TCP, HTTP and gRPC probe inputs and advisories.                                                                                                                                                       |
| 050–051, 082 | Worker starts successfully after the delayed backend goes healthy, outside destinations are absent from the dependency map, and a cyclic project parses with both edges omitted and diagnosed.                 |
| 052–056, 085 | HTTP served through the assigned host binding, exposed private port, mixed project network membership and default routes, internal-only port advisory, and the parsed standalone internal network.             |
| 057–062, 084 | Host source and target in the reference-only artifact, file bytes and ownership in Docker, required and optional interpolation, distinct member values, and the absent optional file with its source advisory. |
| 063–069      | Engine tmpfs type and size, anonymous disk volume, persistent volume surviving down, separate names for matching claims, disk quota advisories, and a read-only mount.                                         |
| 070–071      | Initialization advisory, canonical step, and startup with only primary services despite a failing initialization executable.                                                                                   |
| 072–074      | Native capabilities per service and across the bundle, required capability union, and successful rendering with warnings.                                                                                      |
| 075–081      | Manifest retains directional links, egress restrictions, rollout, placement, singleton, target metric and restart timing. The rendered service contains only their applicable native directives.               |
