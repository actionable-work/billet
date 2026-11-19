# Runtimes

Every runtime target renders from the same canonical definition, so a service
means the same thing wherever it runs. Moving a service between runtimes means
building a different artifact, not rewriting the service.

| Runtime                                | Artifacts                                       | Status      | Guide                                        |
| -------------------------------------- | ----------------------------------------------- | ----------- | -------------------------------------------- |
| Docker                                 | OCI image, OCI layout, Docker archive           | Supported   | [Docker](runtimes/docker.md)                 |
| Docker Compose                         | `compose.yaml` bundle with images and manifests | Supported   | [Docker Compose](runtimes/docker-compose.md) |
| Kubernetes                             | Workload manifests                              | Coming soon |                                              |
| Nix microVM                            | microVM configuration                           | Coming soon |                                              |
| [Hammerworks](https://hammerworks.dev) | Native manifest                                 | Coming soon |                                              |

## What Billet does and what the runtime does

Billet builds artifacts. The runtime that consumes them runs the service and
owns execution, health checks, restarts, rollout, admission, network and
resource enforcement, and secret delivery.

Each artifact carries the canonical manifest, or a reference to it, alongside
the runtime's native configuration. A runtime that reads the manifest can honor
every declaration, even ones its native format can't express. Each guide lists
which declarations the native format applies.

## Contracts

Runtime authors can rely on these contracts:

- [IR contract](../tests/.bloomery/specs/BILLET/IR/design/contract.md)
- [Closure contract](../tests/.bloomery/specs/BILLET/CLOSURE/design/contract.md)
- [OCI packaging](../tests/.bloomery/specs/BILLET/CLOSURE/design/oci.md)
- [Target rendering](../tests/.bloomery/specs/BILLET/IR/design/targets.md)
