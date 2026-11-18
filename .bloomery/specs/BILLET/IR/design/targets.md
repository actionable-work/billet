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
