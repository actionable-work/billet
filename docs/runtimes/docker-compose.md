# Docker Compose

Billet builds a self-contained Compose bundle: the images, a `compose.yaml` that
references them, and the canonical manifests. Compose runs it without pulling or
building anything.

This guide assumes you have a Billet at `.#billets.x86_64-linux.hello`, as in
[Getting started](../getting-started.md). Compose images have the same
requirements as [Docker images](docker.md#requirements).

## Check the Billet can be rendered

```sh
nix eval --json .#billets.x86_64-linux.hello.dockerCompose.capabilityReport
```

The report evaluates without building any packages. When `canRender` is `false`,
each entry in `diagnostics` names the field that blocks rendering and why. The
report also echoes the Billet's `requiredCapabilities`.

## Build the bundle

```sh
nix build .#billets.x86_64-linux.hello.dockerCompose.bundle -o result
```

```text
result/
├── compose.yaml
├── image.tar
└── manifest.json
```

`compose.yaml` contains one service named after `identity.name`:

```yaml
services:
  hello:
    image: hello:7ded9d1e…
    pull_policy: never
x-billet:
  manifest: ./manifest.json
  manifestDigest: sha256:e21c…
```

The file is written as JSON, which is valid YAML.

## Load and run

```sh
docker load --input result/image.tar
docker compose -f result/compose.yaml up --no-build
```

```text
hello-1  | Hello from Billet
hello-1 exited with code 0
```

Stop and remove the project with:

```sh
docker compose -f result/compose.yaml down
```

`pull_policy: never` makes Compose use the image you loaded, and fail rather
than fetch a different one if it is missing. The image supplies the entrypoint,
arguments, environment, user, working directory, and stop signal; see
[Docker](docker.md#run-the-container).

## What Compose receives

The generated service sets only the image. The rest of the definition stays in
`manifest.json`, and the `x-billet` extension points to it with its digest. A
runtime that reads the manifest can honor it; plain Compose ignores it.

| Declared in the Billet | In plain Compose                                            |
| ---------------------- | ----------------------------------------------------------- |
| Process configuration  | Applied, through the image                                  |
| `network.ports`        | Reachable on the project network, not published to the host |
| `resources`            | Not applied                                                 |
| `probes`               | Not applied                                                 |
| `restart`, `rollout`   | Not applied                                                 |
| `secrets`, `storage`   | Not applied                                                 |

To publish ports or set limits for local use, add an override file instead of
editing the generated one:

```yaml
# compose.override.yaml
services:
  hello:
    ports:
      - "8080:8080"
    deploy:
      resources:
        limits:
          cpus: "1"
          memory: 64M
```

```sh
docker compose -f result/compose.yaml -f compose.override.yaml up --no-build
```

## Bundles

A [`mkBilletBundle`](../library.md#mkbilletbundle) renders several services into
one project:

```nix
billets.${system}.catalog-report = billet.lib.mkBilletBundle {
  inherit pkgs;
  billets = { inherit catalog report; };
};
```

Its bundle holds an image and a manifest per member:

```text
result/
├── compose.yaml
├── images/
│   ├── catalog.tar
│   └── report.tar
└── manifests/
    ├── catalog.json
    └── report.json
```

`x-billet.services.<name>` records each member's manifest and digest. Load every
image, then start the project:

```sh
nix build .#billets.x86_64-linux.catalog-report.dockerCompose.bundle -o result
for image in result/images/*.tar; do docker load --input "$image"; done
docker compose -f result/compose.yaml up --no-build
```

Members share the project's default network and reach each other by service
name. In the [catalog-report example](../../examples/catalog-report), `report`
fetches `http://catalog:8080/items.json`.

## Outputs

These attributes exist on both Billets and bundles.

| Attribute                        | Type       | Description                                                  |
| -------------------------------- | ---------- | ------------------------------------------------------------ |
| `dockerCompose.capabilityReport` | Nix value  | Whether Compose artifacts can be rendered, with diagnostics. |
| `dockerCompose.configuration`    | Nix value  | The Compose configuration.                                   |
| `dockerCompose.file`             | derivation | `compose.yaml` on its own.                                   |
| `dockerCompose.bundle`           | derivation | `compose.yaml` with the images and manifests.                |
