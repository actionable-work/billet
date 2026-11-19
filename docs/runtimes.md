# Runtimes

Each target renders from the same canonical definition. The artifact supplies
the native settings available to its consumer and preserves the full declaration
in the manifest. Moving a service between runtimes means building a different
artifact, not rewriting the service.

| Runtime                                | Artifacts                                        | Status      | Guide                                        |
| -------------------------------------- | ------------------------------------------------ | ----------- | -------------------------------------------- |
| Docker                                 | OCI image, OCI layout, Docker archive            | Supported   | [Docker](runtimes/docker.md)                 |
| Docker Compose                         | `compose.yaml` bundle with images and manifests  | Supported   | [Docker Compose](runtimes/docker-compose.md) |
| Kubernetes                             | `kubernetes.json` bundle with image and manifest | Supported   | [Kubernetes](runtimes/kubernetes.md)         |
| Nix microVM                            | microVM configuration                            | Coming soon |                                              |
| [Hammerworks](https://hammerworks.dev) | Native manifest                                  | Coming soon |                                              |

## What Billet does and what the runtime does

Billet builds artifacts. The runtime that consumes them runs the service and
owns execution, health checks, restarts, rollout, admission, network and
resource enforcement, and secret delivery.

Built images embed the manifest. Compose and Kubernetes bundles also ship it
alongside the native configuration. Compose identifies it in `x-billet`.
Consumers can read the manifest for additional policy. The runtime guides
describe which declarations each target supports.

## Contracts

Runtime authors can rely on these contracts:

- [IR contract](../tests/.bloomery/specs/BILLET/IR/design/contract.md)
- [Closure contract](../tests/.bloomery/specs/BILLET/CLOSURE/design/contract.md)
- [OCI packaging](../tests/.bloomery/specs/BILLET/CLOSURE/design/oci.md)
- [Target rendering](../tests/.bloomery/specs/BILLET/IR/design/targets.md)
