# Billet

Billet is a portable Nix module library and renderer toolchain. One Billet
describes one application. Nix modules normalize into versioned, canonical,
secret-free IR and a complete transitive runtime closure descriptor.

BI-P1 provides the public schema, validator, normalized IR and closure tooling.
Docker Compose/OCI and a Bloomery integration harness are next (BI-P2).
Lifecycle declarations are preserved; runtime enforcement requires a conforming
renderer. Lineshaft, standalone MicroVM and Kubernetes outputs follow later.

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
`runtimeRoots` and `closureDescriptor`. The descriptor output contains
`descriptor.json`, `manifest.json` and `store-paths`, with NAR hashes/sizes and
direct edges for every transitive runtime path. Package executable existence,
permissions and containment are checked after realization. Descriptor metadata
does not replace independent NAR verification or runtime admission.

Never pass secret values to Nix. `secrets` accepts reference metadata only and
Billet never resolves it. Nix modules and ordinary environment/argv strings are
trusted public build inputs, so do not read credentials or put secrets in them.
Runtime secret delivery and authorization belong to the target adapter.

The complete field/default/encoding contract is in the repository-owned
[IR specification](.bloomery/specs/BILLET/IR/design/contract.md) and
[closure specification](.bloomery/specs/BILLET/CLOSURE/design/contract.md).
[Traceability](docs/traceability.md) retains source requirement IDs.

## Develop and verify

Bloomery and nixpkgs are public inputs pinned by `flake.lock`; no adjacent
checkout or private service is required. Rust supplies only a thin argument-safe
Nix CLI. Definitions and normalization remain in Nix.

```sh
nix develop --command bloomery sync
nix develop --command nix fmt
nix develop --command bloomery check
nix develop --command nix flake check
jj status
jj diff --stat
```

Use `bloomery sync` after crate/dependency changes. Locks and health baselines are
owned by Bloomery. A failed check provides a retained run and failure ID; inspect
it with `nix develop --command bloomery check details <failure> --run <run>`.
See [BI-P1 evidence and limitations](docs/bi-p1.md) and
[next milestone handoffs](docs/handoffs.md).

Licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
