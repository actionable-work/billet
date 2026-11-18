# Billet

Billet is a portable Nix module library and renderer toolchain. One Billet
describes one application. Nix modules normalize into versioned, canonical,
secret-free IR and a complete transitive runtime closure descriptor.

Billet generates deployment artifacts from IR. Docker images and Docker Compose
are implemented. Kubernetes, Nix microVM, and Hammerworks-native are renderer
families for future slices. The consuming runtime owns execution and lifecycle
policy.

## Try the example

Requires Nix with `nix-command` and `flakes` enabled. From this checkout:

```sh
nix develop --command nix run . -- validate .#billets.x86_64-linux.hello
nix develop --command nix run . -- manifest .#billets.x86_64-linux.hello
nix develop --command nix run . -- closure .#billets.x86_64-linux.hello
nix develop --command nix build .#billets.x86_64-linux.hello.closureDescriptor -o result-hello
cat result-hello/descriptor.json
nix develop --command nix run .#example -- '--greeting=Hello from Billet'
```

The last command runs the example executable with its declared argument.
Replace `x86_64-linux` with your system for standalone evaluation. The flake
exposes x86_64-linux, aarch64-linux and aarch64-darwin; execution evidence is
recorded per system. A consumer may impose a narrower hosted profile.

## Define an application

```nix
# application.nix
{ pkgs, ... }: {
  identity = { name = "hello"; version = "0.1.0"; };
  process = {
    package = pkgs.hello;
    executable = "bin/hello";
    argv = [ "--greeting=Hello from Billet" ];
  };
  resources = {
    cpuRequest = 100; cpuLimit = 1000; # millicores
    memoryRequest = 16777216; memoryLimit = 67108864; # bytes
  };
  secrets.database = {
    external = "environment/database";
    target = "/run/secrets/database";
  };
}
```

With a pinned `billet` flake input, export an instance using:

```nix
billets.${system}.hello = billet.lib.mkBillet {
  pkgs = nixpkgs.legacyPackages.${system};
  modules = [ ./application.nix ];
};
```

Each instance exposes `ir`, `canonicalJSON`, `manifestDigest`, `manifest`,
`runtimeRoots`, `closureDescriptor`, `ociImage`, `ociLayout`, `dockerImage`,
and `dockerCompose`.
The descriptor output contains
`descriptor.json`, `manifest.json` and `store-paths`, with NAR hashes/sizes and
direct edges for every transitive runtime path. Package executable existence,
permissions and containment are checked after realization. Descriptor metadata
does not replace independent NAR verification or runtime admission.

Never pass secret values to Nix. `secrets` accepts reference metadata only and
Billet never resolves it. Nix modules and ordinary environment/argv strings are
trusted public build inputs, so do not read credentials or put secrets in them.
Runtime secret delivery and authorization belong to the consumer.

## Docker and Compose artifacts

Build the bundle and load it with Docker and Compose:

```sh
nix develop --command nix build .#billets.x86_64-linux.hello.dockerCompose.bundle -o result-compose
docker load --input result-compose/image.tar
docker compose -f result-compose/compose.yaml up --no-build
```

The bundle contains `image.tar`, `compose.yaml` and canonical `manifest.json`.
Compose uses the exact locally loaded image. The `x-billet` extension points to
the manifest and records its digest for a consuming runtime. Native Compose
inherits the primary process configuration from the image. Lifecycle policies
such as rollout, readiness and restart stay declarative in `manifest.json`.
`dockerCompose.file` and `dockerImage` also expose the two artifacts individually.
The `billet compose INSTALLABLE` command builds the bundle and prints its path.

```sh
nix develop --command nix run . -- capabilities .#billets.x86_64-linux.hello
nix develop --command nix run . -- image .#billets.x86_64-linux.hello
nix develop --command nix build .#billets.x86_64-linux.hello.ociLayout -o result-oci
cat result-oci/image-digest
# Opt-in local Docker image smoke, with bounded execution and fixture cleanup:
nix develop --command nix run .#tests:oci-smoke -- ./result-oci
```

`ociImage` is a native [nix2container](https://github.com/nlewo/nix2container) image
with upstream copy helpers. `ociLayout` exports it to OCI blobs plus `provenance.json`.
It contains the descriptor's complete store closure and preserves Entrypoint/Cmd
arrays, non-secret environment, user and working directory. Packaging supports
x86_64-linux and aarch64-linux with numeric `uid:gid` users. Other image systems
and user forms fail explicitly; the Nix module interface remains generic.

The `compose-artifact-v1` report checks whether the Docker and Compose artifacts
can be rendered before realizing packages. It also lists the runtime capabilities
declared in the canonical IR.

The complete field/default/encoding contract is in the repository-owned
[IR specification](.bloomery/specs/BILLET/IR/design/contract.md) and
[closure specification](.bloomery/specs/BILLET/CLOSURE/design/contract.md).
[OCI packaging](.bloomery/specs/BILLET/CLOSURE/design/oci.md) and
[target preflight](.bloomery/specs/BILLET/IR/design/targets.md) have separate contracts.
[Traceability](docs/traceability.md) retains source requirement IDs.

## Develop and verify

Bloomery and nixpkgs are public inputs pinned by `flake.lock`; no adjacent
checkout or private service is required. Rust supplies the argument-safe Nix CLI and acceptance/smoke harnesses. Definitions and normalization remain in Nix.

```sh
nix develop --command bloomery sync
nix develop --command nix fmt
nix develop --command bloomery check
nix develop --command nix flake check
nix develop --command nix flake check ./tests
jj status
jj diff --stat
```

Use `bloomery sync` after crate/dependency changes. Locks and health baselines are
owned by Bloomery. A failed check provides a retained run and failure ID; inspect
it with `nix develop --command bloomery check details <failure> --run <run>`.
See [BI-P1 evidence](docs/bi-p1.md),
[Docker and Compose evidence](docs/compose-artifacts.md), and
[artifact consumer handoffs](docs/handoffs.md).

Licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
