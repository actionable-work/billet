# Billet

Billet lets you define your services once and run them on any runtime.

You describe each application with a small Nix module: what to run, what it
needs, and how it should behave. Billet turns that definition into deployment
artifacts for Docker, Docker Compose, Kubernetes, Nix microVMs, and Hammerworks.
The service definition stays the same regardless of where it runs.

## Who it's for

- **Teams that deploy the same service in several places**, such as Compose for
  local development, Kubernetes in production, and microVMs at the edge, and
  want one source of truth instead of a set of manifests that drift apart.
- **Nix users** who want reproducible, minimal images built from the exact
  runtime closure of their packages.
- **Platform and runtime authors** who need a stable, validated description of
  an application to consume, without coupling it to how it was built.

## Why

Deployment configuration is usually written per runtime, so moving a service
means rewriting it. Billet separates _what a service is_ from _where it runs_:

- **One definition.** Each Billet describes one application. Its identity,
  process, resources, secret references, and lifecycle policy are declared once.
- **A canonical, portable IR.** Definitions normalize into a versioned,
  validated intermediate representation. Each target renders supported runtime
  native settings from that IR.
- **Slim, reproducible images.** Images contain only the service's transitive
  Nix runtime closure, which reduces image size and attack surface.
- **Secret-free by design.** Billet records only references to secrets. The
  runtime resolves and delivers the values.
- **Artifacts, not a runtime.** Billet produces standard artifacts that follow
  each runtime's conventions. You don't need a custom runtime to use Billets.

## Billet and Hammerworks

Billet is the way to deploy services to [Hammerworks](https://hammerworks.dev).
The Billet you deploy there is the same one you run locally with Docker Compose
or hand to another runtime. You can start on Hammerworks and move a service
elsewhere, or bring an existing Billet onto Hammerworks, without changing its
definition.

## Supported runtimes

| Runtime                                | Artifacts                                        | Status      |
| -------------------------------------- | ------------------------------------------------ | ----------- |
| Docker                                 | OCI image, OCI layout, Docker archive            | Supported   |
| Docker Compose                         | `compose.yaml` bundle with images and manifests  | Supported   |
| Kubernetes                             | `kubernetes.json` bundle with image and manifest | Supported   |
| Nix microVM                            | QEMU guest runner, settings, and manifest        | Supported   |
| [Hammerworks](https://hammerworks.dev) | Native manifest                                  | Coming soon |

Images build for `x86_64-linux` and `aarch64-linux`. See
[Runtimes](docs/runtimes.md) for a guide to each runtime.

## Getting started

Enable the `nix-command` and `flakes` features, then define an application:

<!-- doctest: readme-application -->

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

Export it from your flake:

<!-- doctest: readme-flake -->

```nix
{
  inputs.billet.url = "github:actionable-work/billet";
  inputs.nixpkgs.follows = "billet/nixpkgs";

  outputs = { billet, nixpkgs, ... }: {
    billets.x86_64-linux.hello = billet.lib.mkBillet {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [ ./application.nix ];
    };
  };
}
```

Build the Docker Compose bundle and run it:

<!-- doctest: readme-compose -->

```sh
nix build .#billets.x86_64-linux.hello.dockerCompose.bundle -o result
docker load --input result/image.tar
docker compose -f result/compose.yaml up --no-build
```

[Getting started](docs/getting-started.md) walks through the example in more
detail.

## Examples

| Example                                   | Shows                                                                                |
| ----------------------------------------- | ------------------------------------------------------------------------------------ |
| [hello](examples/hello)                   | A single nixpkgs package as a Billet.                                                |
| [catalog-report](examples/catalog-report) | A Rust catalog built with Bloomery and a curl-based reporting service in one bundle. |

## Documentation

- [Getting started](docs/getting-started.md)
- [Application modules](docs/modules.md): every field you can declare
- [Library functions](docs/library.md): `mkBillet` and `mkBilletBundle`, with
  their arguments and outputs
- [Runtimes](docs/runtimes.md): supported targets and their status
  - [Docker](docs/runtimes/docker.md)
  - [Docker Compose](docs/runtimes/docker-compose.md)
- [Bloomery integration](docs/bloomery.md)
- [Secrets](docs/secrets.md)

## Development

Run `nix fmt` from the repository root to format the checkout, and
`./tests/ci.sh` to verify the root flake, examples, and qualification checks.
See [AGENTS.md](AGENTS.md) for the development workflow.

## License

Licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at
your option.
