# Target artifact boundary

Billet produces target artifacts from canonical Nix IR. Docker, Compose,
Kubernetes, Nix microVM and Hammerworks-native are separate renderer families.
A consuming runtime owns application execution and all lifecycle policy.
Required capabilities remain part of the canonical IR even when a native
artifact consumer ignores that metadata.

## Docker image

The existing pinned nix2container image and OCI layout retain their application
closure, primary process configuration and identity. Export that same image to
a Docker-loadable archive using its exact content-derived image reference.
The archive build operates without a Docker daemon.

## Compose artifact

Render one application service keyed by the IR identity name. Reference the
exact exported image and require a locally loaded image with pull policy
`never`. Compose inherits the entrypoint, argv, environment, user, and working
directory from the image. The native service has no injected lifecycle control
or secret values. A top-level `x-billet` extension gives the configured runtime
the canonical manifest's relative path and exact digest. Write the Compose
document as JSON, a YAML subset accepted by the pinned Compose consumer.

Provide the configuration as a pure Nix value, the standalone Compose file,
and a bundle directory containing `compose.yaml`, `image.tar`, and
`manifest.json`. The bundle contains the canonical IR bytes including policy
declarations and reference-only secret metadata.

### Multi-service bundles

`lib.mkBilletBundle { pkgs; billets; }` accepts a nonempty attrset of already
evaluated Billets on the selected package-set system. Each key must match its
Billet's canonical application identity. The bundle exposes its members under
`billets` and uses the same `dockerCompose` output selectors as `mkBillet`.
Its preflight includes each member's report, the union of required capabilities,
and service-scoped diagnostics. An invalid bundle or member prevents rendering
before any image is built.

Merge the member service definitions into one Compose file. Package each image
under `images/<service>.tar` and its canonical IR under `manifests/<service>.json`.
The bundle's `x-billet.services` extension records the relative manifest path
and digest for each service.

### Multi-service example

The `billets.<system>.catalog-report` example uses this bundle interface. The
catalog serves JSON on the Compose network. The report fetches it by
service name and exits. The example uses native Compose service discovery and
requires no published host port. Verify that each archived image and manifest
matches its service and that the report receives the JSON in the Docker VM.

### Example subflakes

Each example owns its `billets` output and supports direct builds from its
directory. The hello subflake consumes Billet directly and exports an app that
uses its Billet's selected executable. The catalog-report subflake uses
Bloomery's `billets` callback to expose both services and their Compose bundle.
It passes the Rust workspace's exported `catalog` package as the primary
process package. The report fetches inventory from the Rust catalog in Compose.

## Artifact preflight

The versioned capability report measures artifact eligibility. It echoes the
IR-required capabilities for the consumer and claims no runtime capabilities.
Use the shared image diagnostics for an unsupported system or user. Diagnose
such inputs during evaluation before image construction. Evaluating a supported
configuration does not realize the application package. Runtime capabilities,
including required defaults, remain declared in the manifest.

## Qualification

Verify the pure configuration against an unrealizable fixture, including image
reference, one service, preserved required capabilities, and redacted field
diagnostics. In an automated isolated Linux VM, load the exported archive,
validate the rendered configuration with the pinned Compose CLI, and run the
declared primary process through that Compose file. Assert exact canonical
manifest bytes and verify that no lifecycle controller or credential value is
added to the artifacts.
