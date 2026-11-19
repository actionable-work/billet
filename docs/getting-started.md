# Getting started

This guide defines a Billet, validates it, and inspects what Billet produces
from it. The steps are the same whichever runtime you deploy to. When you're
done, follow the guide for your runtime.

## Requirements

- Nix with the `nix-command` and `flakes` features enabled.
- An `x86_64-linux` or `aarch64-linux` builder to build images. Definitions
  evaluate on any system, including `aarch64-darwin`.

## 1. Define the application

A Billet is a Nix module that describes one application:

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
    cpuRequest = 100; cpuLimit = 1000;                # millicores
    memoryRequest = 16777216; memoryLimit = 67108864; # bytes
  };
}
```

`identity`, `process.package`, `process.executable`, and the four `resources`
values are required. Everything else has a default. See
[Application modules](modules.md) for every field, and [Secrets](secrets.md) for
declaring credentials.

## 2. Export it from a flake

```nix
# flake.nix
{
  inputs.billet.url = "github:actionable-work/billet";
  inputs.nixpkgs.follows = "billet/nixpkgs";

  outputs = { billet, nixpkgs, ... }: let
    systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
    eachSystem = nixpkgs.lib.genAttrs systems;
    billets = eachSystem (system: {
      hello = billet.lib.mkBillet {
        pkgs = nixpkgs.legacyPackages.${system};
        modules = [ ./application.nix ];
      };
    });
  in {
    inherit billets;
    checks = eachSystem (system: {
      "billet:hello:validate" = billets.${system}.hello.validationCheck;
    });
  };
}
```

Billets live at `billets.<system>.<name>`. The examples below use
`x86_64-linux`; substitute your system.

## 3. Validate the definition

```sh
nix flake check
```

`validationCheck` evaluates the whole definition without building the package.
An invalid definition fails with the path of the offending field:

```text
error: billet: resources.cpuRequest: exceeds limit
```

## 4. Inspect the canonical definition

```sh
nix eval --raw .#billets.x86_64-linux.hello.canonicalJSON
```

This is the normalized definition, with every default filled in. Every runtime
renders from it, so it is the single description of what the service is.
`manifestDigest` identifies it:

```sh
nix eval --raw .#billets.x86_64-linux.hello.manifestDigest
```

The `requiredCapabilities` field lists what a runtime must provide to run the
service as declared, such as `resources`, `shutdown`, or `rolling-rollout`.
Adding probes, secrets, ports, or storage adds to that list.

## 5. Inspect the runtime closure

```sh
nix build .#billets.x86_64-linux.hello.closureDescriptor -o result-closure
cat result-closure/descriptor.json
```

The descriptor lists every store path the service needs at runtime, with NAR
hashes and references. Building it also confirms that every declared executable
exists. Every image Billet builds contains exactly this closure.

## 6. Deploy to a runtime

The same Billet now builds artifacts for each runtime:

- [Docker](runtimes/docker.md): build and run the OCI image.
- [Docker Compose](runtimes/docker-compose.md): build and run one or more OCI
  images in a compose environment.
- [Kubernetes](runtimes/kubernetes.md): build a Kubernetes List with the image
  and apply it to a cluster.

See [Runtimes](runtimes.md) for every runtime and its status.

## Next steps

- Add ports, probes, and storage with [Application modules](modules.md).
- Group several services with [`mkBilletBundle`](library.md#mkbilletbundle).
- Build services from a Rust workspace with [Bloomery](bloomery.md).
