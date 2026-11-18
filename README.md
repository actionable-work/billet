# Billet

Billet is a portable Nix module library and renderer toolchain. One Billet
describes one application. Nix modules normalize into versioned, canonical,
secret-free IR and a complete transitive runtime closure descriptor.

Billet generates deployment artifacts from IR. Docker images and Docker Compose
are implemented. Kubernetes, Nix microVM, and Hammerworks-native are renderer
families for future slices. The consuming runtime owns execution and lifecycle
policy.

## Try the example

Enable `nix-command` and `flakes` in Nix. From this checkout, run:

```sh
nix build ./examples/hello#checks.x86_64-linux.billet:hello:validate
nix eval --raw ./examples/hello#billets.x86_64-linux.hello.canonicalJSON
nix build ./examples/hello#billets.x86_64-linux.hello.closureDescriptor -o result-hello
cat result-hello/descriptor.json
nix run ./examples/hello -- '--greeting=Hello from Billet'
```

The last command runs the example executable with its declared argument.
Replace `x86_64-linux` with your system for standalone evaluation. The flake
exposes x86_64-linux, aarch64-linux and aarch64-darwin; execution evidence is
recorded per system. A consumer may impose a narrower hosted profile.

## Example repository layouts

The public root flake exports the Nix library. The example flakes consume
it independently and expose their own `billets` outputs.

| Example | Start here |
| --- | --- |
| [hello](examples/hello/flake.nix) | A minimal flake that deploys a nixpkgs package using one [Billet module](examples/hello/application.nix). |
| [catalog-report](examples/catalog-report/flake.nix) | A Bloomery Rust workspace with its own [Cargo manifest](examples/catalog-report/Cargo.toml), [Bloomery config](examples/catalog-report/.bloomery/config.toml), and [Billet definitions](examples/catalog-report/billets.nix). |

The example flakes use `path:../..` to consume Billet from this checkout.
When adapting one to a separate repository, point its `billet` input at a
published Billet revision and regenerate its flake lock.

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

Each instance exposes `ir`, `canonicalJSON`, `manifestDigest`, `manifest`, `validationCheck`,
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
nix build ./examples/hello#billets.x86_64-linux.hello.dockerCompose.bundle -o result-compose
docker load --input result-compose/image.tar
docker compose -f result-compose/compose.yaml up --no-build
```

The bundle contains `image.tar`, `compose.yaml` and canonical `manifest.json`.
Compose uses the exact locally loaded image. The `x-billet` extension points to
the manifest and records its digest for a consuming runtime. Native Compose
inherits the primary process configuration from the image. Lifecycle policies
such as rollout, readiness and restart stay declarative in `manifest.json`.
`dockerCompose.file` and `dockerImage` also expose the two artifacts individually.

### Multi-service example

`catalog-report` runs two Billets on a shared Compose network. Bloomery builds
the [Rust catalog](examples/catalog-report/packages/rust/catalog/src/main.rs)
as `packages.<system>.catalog`. The catalog Billet takes that derivation as
`process.package` and packages its executable into the Docker image. The
`report` service fetches inventory at
`http://catalog:8080/items.json`, prints it, and exits. Each service has its own
image archive and canonical manifest in the bundle.

The application flake consumes Billet and Bloomery as siblings. Its
`bloomery.mkFlake` arguments include:

```nix
billets = import ./billets.nix { billetLib = billet.lib; };
```

The definition receives `{ pkgs, packages }` for each system and returns
`catalog`, `report`, and `catalog-report`. Bloomery exposes each entry at
`billets.<system>.<name>` and registers `billet:<name>:validate` checks. The
validation checks verify the normalized definitions without building images.

To build and check the Rust workspace from the example directory:

```sh
cd examples/catalog-report
nix develop --command nix build .#catalog
nix develop --command bloomery check
```

To build and run the example's Docker Compose bundle from the repository root:

```sh
nix build \
  ./examples/catalog-report#billets.x86_64-linux.catalog-report.dockerCompose.bundle \
  -o result-catalog-report

for image in result-catalog-report/images/*.tar; do
  docker load --input "$image"
done

docker compose -p billet-catalog-report -f result-catalog-report/compose.yaml \
  up --no-build --exit-code-from report
docker compose -p billet-catalog-report -f result-catalog-report/compose.yaml down
```

The `report` log should contain `{"items":[{"inStock":true,"sku":"notebook"}]}`.

To group your own evaluated Billets, export a bundle alongside individual
Billets:

```nix
billets.${system}.catalog-report = billet.lib.mkBilletBundle {
  inherit pkgs;
  billets = { inherit catalog report; };
};
```

Member keys must match the application identities. Bundles use the same
`dockerCompose` selectors as individual Billets.

```sh
nix eval --json ./examples/hello#billets.x86_64-linux.hello.dockerCompose.capabilityReport
nix build ./examples/hello#billets.x86_64-linux.hello.ociImage
nix build ./examples/hello#billets.x86_64-linux.hello.ociLayout -o result-oci
cat result-oci/image-digest
# Opt-in local Docker image smoke, with bounded execution and fixture cleanup:
nix run ./tests#oci-smoke -- ./result-oci
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
[IR specification](tests/.bloomery/specs/BILLET/IR/design/contract.md) and
[closure specification](tests/.bloomery/specs/BILLET/CLOSURE/design/contract.md).
[OCI packaging](tests/.bloomery/specs/BILLET/CLOSURE/design/oci.md) and
[target preflight](tests/.bloomery/specs/BILLET/IR/design/targets.md) have separate contracts.
[Traceability](docs/traceability.md) retains source requirement IDs.

## Develop and verify

CI runs the public flake, both examples, and the qualification subflake. The
Docker qualification check runs on Linux with KVM. The test subflake builds
the Rust acceptance and smoke harnesses with Bloomery.

```sh
nix run ./tests#ci   # runs ./tests/ci.sh from anywhere in the checkout
cd tests
nix develop --command bloomery sync
nix develop --command nix fmt
nix develop --command bloomery check
nix develop --command nix flake check
```

The test flake's `nix fmt` formats `tests/`; `billet:public-format` checks the
root flake, `lib/`, and the hello example.

Set `BILLET_BLOOMERY_FLAKE` to a flake reference to exercise a different
Bloomery revision in the example and qualification flakes. For an in-progress
Bloomery checkout, use an absolute `path:` reference.

Use `bloomery sync` after crate/dependency changes. Locks and health baselines are
owned by Bloomery. A failed check provides a retained run and failure ID; inspect
it with `nix develop --command bloomery check details <failure> --run <run>`.
See [BI-P1 evidence](docs/bi-p1.md),
[Docker and Compose evidence](docs/compose-artifacts.md), and
[artifact consumer handoffs](docs/handoffs.md).

Licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
