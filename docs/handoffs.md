# Artifact consumer handoffs

## Docker and Compose

The artifact bundle carries a Docker archive, `compose.yaml`, and the exact
canonical `manifest.json`. The Compose service uses the archive image reference.
The `x-billet` extension identifies the relative manifest path and digest.
The consuming runtime decides whether it can admit the declaration and owns its
execution and lifecycle semantics, including rollout and secret authorization.

## Other renderer families

Kubernetes, Nix microVM, and Hammerworks-native each need a specific artifact
contract and automated consumer acceptance. Reuse the normalized IR and
descriptor rather than introducing a separate application definition schema.
Keep target capability reporting scoped to rendering, and preserve declaration
metadata for a consumer to interpret.

## Consumer boundary

Consumers own admission profiles, credential resolution and artifact trust.
Canonical metadata identifies contents and declared policy. Consumer-specific
platform restrictions remain distinct from the portable `mkBillet` schema.
The pinned public Bloomery flake composes the standalone test subflake with the
parent build, including artifact acceptance and diagnostics.
