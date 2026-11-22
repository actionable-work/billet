# Docker Compose

Billet bundles the images, their canonical manifests, and a `compose.yaml` with
native service settings. Load the images locally before starting the project.
Supply any declared secret values separately at startup.

This guide assumes you have a Billet at `.#billets.x86_64-linux.hello`, as in
[Getting started](../getting-started.md). To run the project, use Docker Engine
with the Docker Compose CLI. Compose images have the same build and user
requirements as [Docker images](docker.md#requirements).

## Check the Billet can be rendered

<!-- doctest: compose-report -->

```sh
nix eval --json .#billets.x86_64-linux.hello.dockerCompose.capabilityReport
```

The report evaluates without building any packages. `canRender` indicates
whether Billet can produce the artifacts. When it is `false`, check
`diagnostics` for packaging or bundle errors. Diagnostics with
`severity = "warning"` describe mapping limitations and allow rendering. For
example, the hello report warns about CPU reservations and still has
`canRender = true`.

`requiredCapabilities` comes from the IR. `supportedCapabilities` names native
mappings used by the rendered project. A name can cover a partial mapping. For
example, `resources` covers CPU and memory limits and memory reservation in
standalone Compose. For a bundle, the report also includes per-service reports
and service-scoped diagnostics.

Compose bundles preserve bandwidth minimums and maximums in each canonical
manifest. Preflight warns at every configured bound because enforcement requires
consumer-managed networking. A consumer must enforce the requested bounds before
admitting the service.

## Build the bundle

<!-- doctest: compose-build -->

```sh
nix build .#billets.x86_64-linux.hello.dockerCompose.bundle -o result
```

```text
result/
├── compose.yaml
├── image.tar
└── manifest.json
```

`compose.yaml` contains one service named after `identity.name`. The image tag
and manifest digest are abbreviated here.

```yaml
services:
  hello:
    image: hello:7ded9d1e…
    pull_policy: never
    restart: on-failure:5
    stop_signal: SIGTERM
    stop_grace_period: 30s
    deploy:
      replicas: 1
      resources:
        limits:
          cpus: "1.000"
          memory: "67108864"
        reservations:
          cpus: "0.100"
          memory: "16777216"
x-billet:
  manifest: ./manifest.json
  manifestDigest: sha256:e21c…
```

The file is written as JSON, which is valid YAML.

## Load and run

<!-- doctest: compose-up -->

```sh
docker load --input result/image.tar
docker compose -f result/compose.yaml up --no-build
```

```text
hello-1  | Hello from Billet
hello-1 exited with code 0
```

Stop and remove the project with:

<!-- doctest: compose-down -->

```sh
docker compose -f result/compose.yaml down
```

`pull_policy: never` makes Compose use the image you loaded, and fail rather
than fetch a different one if it is missing. The image supplies the entrypoint,
arguments, ordinary environment, user, and working directory. See
[Docker](docker.md#run-the-container).

## What Compose receives

The `x-billet` extension identifies the canonical manifest and its digest. The
manifest retains the full declaration.

| Declared in the Billet                                      | In standalone Docker Compose                                                                                                                                                                                      |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `resources.cpuLimit`, `resources.memoryLimit`               | `deploy.resources.limits` in decimal CPU cores and bytes.                                                                                                                                                         |
| `resources.cpuRequest`, `resources.memoryRequest`           | `deploy.resources.reservations` in the same units. Docker Compose applies the memory reservation. CPU reservation is a Swarm feature.                                                                             |
| `resources.replicas`                                        | A fixed replica count at `min`, including zero. A range produces an advisory.                                                                                                                                     |
| `shutdown.stopSignal`, `shutdown.stopGracePeriodSeconds`    | `stop_signal` and `stop_grace_period`.                                                                                                                                                                            |
| `restart.enabled`, `restart.maxRetries`, `restart.triggers` | `on-failure:N` for enabled, positive-retry `unexpected-exit` policies. Exit code zero ends the container. Disabled restart, zero retries, and policies without `unexpected-exit` use `"no"`.                      |
| Exec readiness or liveness probe                            | One `CMD` healthcheck, preferring exec readiness. Its interval, timeout and failure threshold become the Compose healthcheck settings. Liveness reports health for operators.                                     |
| Startup probe and `initialization.startupAllowanceSeconds`  | For a rendered healthcheck, `start_period` uses the startup probe's interval times its failure threshold, or the initialization allowance if no startup probe is declared. Startup commands stay in the manifest. |
| TCP, HTTP and gRPC probes                                   | A capability diagnostic identifies each probe that needs an in-image client.                                                                                                                                      |
| `initialization.steps`                                      | Steps stay in the manifest with a diagnostic. Compose has no equivalent that runs inside the same container on every start.                                                                                       |
| Public and private ports                                    | `ports` publishes public TCP transport ports with host ports assigned by Docker. `expose` records private ports. HTTP and gRPC use TCP.                                                                           |
| `network.publicEgress`                                      | A service with egress disabled joins only the internal project network. Its public ports are recorded in `expose` with an advisory because Docker cannot publish ports from an internal-only network.             |
| File secrets                                                | Environment-sourced Compose secrets delivered at the declared absolute path, readable by the image user.                                                                                                          |
| Environment secrets                                         | Compose interpolates host variables into the declared container environment keys. Required variables must be set and nonempty. Optional variables default to empty.                                               |
| Ephemeral memory storage                                    | A tmpfs mount sized in bytes.                                                                                                                                                                                     |
| Ephemeral disk storage                                      | An anonymous local volume.                                                                                                                                                                                        |
| Persistent disk storage                                     | A named local volume scoped to the project and service. `docker compose down` retains it.                                                                                                                         |

Compose can represent whole-second durations up to `9223372036` seconds. Billet
rejects a larger shutdown grace period or a larger interval or timeout on the
selected exec healthcheck. Preflight identifies the offending field. For a
derived healthcheck start period above the limit, Billet caps the period and
reports an advisory.

Preflight rejects a CPU limit above `9223371264000` millicores. Higher values
overflow the conversion to Engine nanocores. The Engine also checks requested
CPU limits against the host's available CPUs.

Docker Compose uses the declared storage target and honors `readOnlyMany` as a
read-only mount. Volume access topology and driver class stay in the manifest.
Preflight rejects storage and file secret mounts that overlap `/nix/store`,
`/etc/billet/manifest.json`, or `/etc/billet/closure.json`. Disk claims generate
a diagnostic for the missing size limit. To remove a project along with its
declared named volumes and attached anonymous volumes, use
`docker compose down --volumes`.

Rollout, placement, strict singleton, target-metric scaling, the replica maximum
as a scaling bound, restart backoff and jitter, the restart ready-reset window,
startup- and liveness-triggered restarts, directional private connection policy,
and egress restrictions stay in the manifest.

Look up the host port assigned to a published container port after startup. For
a service with multiple replicas, pass `--index` to select a replica. Services
on the same network can connect to listening container ports by service name.

<!-- doctest: skip template for a service that publishes a container port; the examples publish none -->

```sh
docker compose -f result/compose.yaml port my-service 8080
```

## Provide secrets at startup

Set host environment variables when running Compose. The variable name is
`BILLET_SECRET_<service>__<logical-secret>`, using the Billet's `identity.name`
and the key in its `secrets` map. Encode each name with case preserved, using
`_H` for hyphen, `_D` for dot, and `_U` for underscore. For example, a secret
named `db.password` on `my-service` uses
`BILLET_SECRET_my_Hservice__db_Dpassword`. The `external` reference stays in the
canonical manifest.

For file delivery, Compose requires the host variable to be set, even for an
optional file secret. A nonempty value creates the file with owner-only read
permission for the image user. An empty value leaves the file absent, even if
the declaration marks it required. For environment delivery, Compose fails
configuration when a required variable is missing or empty and uses an empty
string for an unset optional variable. Supply these values only to Compose at
runtime.

## Bundles

A [`mkBilletBundle`](../library.md#mkbilletbundle) renders several services into
one project:

```nix
billets.${system}.catalog-report = billet.lib.mkBilletBundle {
  inherit pkgs;
  billets = { inherit catalog report; };
};
```

Its bundle holds an image and a manifest per member:

```text
result/
├── compose.yaml
├── images/
│   ├── catalog.tar
│   └── report.tar
└── manifests/
    ├── catalog.json
    └── report.json
```

`x-billet.services.<name>` records each member's manifest and digest. To try the
[catalog-report example](../../examples/catalog-report), run these commands from
its directory. Load every image, then start the project:

<!-- doctest: compose-bundle -->

```sh
nix build .#billets.x86_64-linux.catalog-report.dockerCompose.bundle -o result
for image in result/images/*.tar; do docker load --input "$image"; done
docker compose -f result/compose.yaml up --no-build
```

The report prints the catalog inventory and exits, while the catalog keeps
serving. Press Ctrl-C to stop the project.

Members reach each other by service name. When every member allows egress,
members share the default network. When any member disables egress, members
share an internal network and members that allow egress also join a non-internal
network.

Compose collects `privateConnections` links from all members. A link between
distinct members makes its source wait for an exec readiness healthcheck on its
destination when the destination has a positive replica count. Preflight rejects
a link to a member if the named port is missing or its protocol differs. Cyclic
readiness dependencies are omitted with a diagnostic. Compose uses these
dependencies for startup ordering. Directional network policy stays in the
manifest. Secret and persistent volume keys are scoped by the encoded member and
logical name so members can reuse logical names.

In the [catalog-report example](../../examples/catalog-report), `report` fetches
`http://catalog:8080/items.json` over the shared network. The catalog's port
uses the default private exposure.

## Outputs

These attributes exist on both Billets and bundles.

| Attribute                        | Type       | Description                                                  |
| -------------------------------- | ---------- | ------------------------------------------------------------ |
| `dockerCompose.capabilityReport` | Nix value  | Whether Compose artifacts can be rendered, with diagnostics. |
| `dockerCompose.configuration`    | Nix value  | The Compose configuration.                                   |
| `dockerCompose.file`             | derivation | `compose.yaml` on its own.                                   |
| `dockerCompose.bundle`           | derivation | `compose.yaml` with the images and manifests.                |
