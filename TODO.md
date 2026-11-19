# TODO

## Docker Compose

The generated service sets only `image` and `pull_policy`; everything else stays
in `manifest.json`. These Billet declarations have a Compose analog and should
be rendered into the service. Each needs a target-contract update in
`tests/.bloomery/specs/BILLET/IR/design/targets.md`, granular `TARGETS` records,
assertions in the Docker VM check, and a row in
`docs/runtimes/docker-compose.md`.

### Resources and replicas

- [ ] `resources.cpuLimit`, `memoryLimit` → `deploy.resources.limits.cpus` and
      `memory` (millicores → decimal CPUs, bytes → byte count).
- [ ] `resources.cpuRequest`, `memoryRequest` →
      `deploy.resources.reservations.cpus` and `memory`.
- [ ] `resources.replicas.min` → `deploy.replicas` when `min == max`. Decide
      whether `max > min` renders `min` or is diagnosed; autoscaling has no
      analog.

### Lifecycle

- [ ] `shutdown.stopSignal`, `stopGracePeriodSeconds` → `stop_signal`,
      `stop_grace_period`. The image already sets `StopSignal`; the grace period
      is missing.
- [ ] `restart.enabled`, `maxRetries` → `restart: on-failure:<maxRetries>`, or
      `"no"` when disabled. Backoff timing, jitter, the ready-reset window, and
      the `liveness-failure`/`startup-failure` triggers have no analog. Decide
      whether `unexpected-exit` should also cover a zero exit (`always` ignores
      the retry limit).
- [ ] Exec probes → `healthcheck`: `test` as a `CMD` array (never a shell
      string), `interval`, `timeout`, `retries` from `failureThreshold`. Map
      readiness first, then liveness; take `start_period` from the startup probe
      or `initialization.startupAllowanceSeconds`. Compose doesn't restart
      unhealthy containers, so liveness only reports.
- [ ] `tcp`, `http`, and `grpc` probes need a client inside the image, which
      Billet images don't have. Diagnose them in the capability report, or add a
      probe helper to the image closure.
- [ ] `depends_on` with `condition: service_healthy` between bundle members that
      declare readiness and their `privateConnections` sources.

### Networking

- [ ] `network.ports` with `exposure = "public"` → `ports` published to the
      host. Private ports → `expose`.
- [ ] `network.publicEgress = false` → attach the service only to an
      `internal: true` bundle network. Services with egress also join a
      non-internal network. Check that published ports still work.
- [ ] `privateConnections` and `egressRestrictions` have no Compose analog;
      leave them to the manifest.

### Secrets

- [ ] File-mode secrets → top-level `secrets` sourced from a host environment
      variable or file, and a service `secrets` entry whose `target` is the
      declared path. Choose and document the host-side naming convention (for
      example `BILLET_SECRET_<NAME>`); the value is supplied when Compose runs,
      never through Nix.
- [ ] Environment-mode secrets → service `environment` using interpolation,
      `${BILLET_SECRET_<NAME>:?...}` when `required`, so Compose fails if it is
      missing.
- [ ] Namespace secret names per member in bundles to avoid collisions.

### Storage

- [ ] Ephemeral `memory` storage → `tmpfs` mount with `size` from `sizeBytes`.
- [ ] Ephemeral `disk` storage → an anonymous volume, or `tmpfs` if disk backing
      doesn't matter. Size limits have no analog for local volumes.
- [ ] Persistent storage → a named top-level volume mounted at `mountPoint`,
      namespaced per member in bundles. `accessMode` and `driverClass` have no
      reliable analog.

### Initialization

- [ ] `initialization.steps` could run as one-shot services that the primary
      waits on with `condition: service_completed_successfully`. They wouldn't
      share the primary container's filesystem or rerun on every restart, so
      decide whether that analog is close enough or should be diagnosed.

### No analog

These stay manifest-only; the Compose guide should list them: `rollout`,
`placement`, `strictSingleton`, `targetMetric`, `replicas.max` scaling, restart
backoff, directional `privateConnections`, and `egressRestrictions`.

### Capability report

- [ ] Populate `supportedCapabilities` with what the rendered file enforces,
      such as `resources`, `shutdown`, `probes`, `runtime-secrets`,
      `network-ports`, and `storage-ephemeral-memory`, instead of `[]`.
