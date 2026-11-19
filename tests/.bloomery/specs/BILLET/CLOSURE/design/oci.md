# OCI closure image adapter v1

`mkBillet` exposes `ociImage`, the native image derivation produced by the
public, flake-locked
[nix2container buildImage API](https://github.com/nlewo/nix2container#nix2containerbuildimage).
`ociLayout` exports that image through nix2container's supported Skopeo copy API
to an
[OCI layout](https://github.com/opencontainers/image-spec/blob/v1.1.1/image-layout.md).
Billet owns service semantics, closure selection and provenance; nix2container
owns layer creation, image manifests and transport. No custom OCI/tar packer.

The adapter consumes canonical IR and the realized closure descriptor. Support
x86_64-linux → linux/amd64 and aarch64-linux → linux/arm64. Reject unsupported
systems, schema/normalization versions, builder/system mismatches, and
nonnumeric uid:gid users before image preparation. IDs must be below the
reserved unsigned 32-bit maximum, without leading zeroes except zero. Generic
modules retain their broader system interface. Never read credentials or resolve
runtime secrets.

## Contents and execution parameters

Use nix2container.buildLayer with explicit runtimeRoots, retaining the complete
transitive closure, including init/probe/config-only dependencies. Use
copyToRoot only for metadata and structural directories. The final filesystem
contains the descriptor's exact store paths, structural directories, declared
working directory and canonical manifest/descriptor under /etc/billet. No host
store mounts, build-tool paths, base registry image, anonymous volumes or
network fetches.

Pass OCI config arrays directly to buildImage: absolute primary executable in
Entrypoint, ordered argv in Cmd, sorted non-secret NAME=value Env, and declared
User/WorkingDir/StopSignal. No shell is introduced. Labels bind system, Billet
manifest/schema and adapter/backend revision. Secret metadata remains in the
public manifest only; never add secret values, runtime credentials or resolvers.
A store working directory must be present in the realized closure. Metadata file
collisions fail with a process.workingDirectory diagnostic.

An image's primary command does not implement init/probes, durable restart,
full-tree shutdown, rollout, runtime secrets, network, resource or storage
policy. Image smoke does not establish those target capabilities.

## Determinism and provenance

Pin nix2container and make its nixpkgs input follow the project's public pin.
Name the image `identity.imageName` from the IR and use a content-derived tag,
so a changed definition always produces a new reference. Use a fixed creation
epoch. Backend layer encoding and permissions are tested against the declared
Nix store trees. Do not patch or reimplement its serialization. Export with the
supported copy API; verify OCI blob digests/sizes and uncompressed layer DiffIDs
independently. Copying twice must reproduce all layout/blob bytes, including
compressed layers if used.

The exported layout includes image-digest and provenance.json v1 binding Billet
manifest digest, system, adapter version, nix2container revision, image manifest
digest and descriptor SHA-256. Image identity differs from Billet identity. The
native image retains upstream copyTo/copyToDockerDaemon/copyToPodman helpers;
registry publication requires separate user authorization.

Acceptance checks native backend output, exported config and complete
filesystem, symlinks/executable modes, bundled metadata, all runtime roots,
absence of builder paths and repeatable independent exports. A bounded opt-in
Docker smoke uses Skopeo transport and cleans only its own fixtures, preserving
existing images. Compose conformance remains separately gated.
