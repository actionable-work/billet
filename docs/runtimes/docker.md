# Docker

Billet builds an OCI image for each service. You can load it into Docker, push
it to a registry, or export it as an OCI image layout for other tools.

This guide assumes you have a Billet at `.#billets.x86_64-linux.hello`, as in
[Getting started](../getting-started.md).

## Requirements

- An `x86_64-linux` or `aarch64-linux` builder. The image architecture matches
  the Billet's system (`amd64` or `arm64`).
- A numeric `process.user` such as `"1000:1000"`. The default, `"65534:65534"`,
  works.
- Docker, to run the image.

## Build and load the image

The quickest path is a Docker archive:

```sh
nix build .#billets.x86_64-linux.hello.dockerImage -o hello.tar
docker load --input hello.tar
```

`docker load` prints the image reference:

```text
Loaded image: hello:7ded9d1e081f6d5cc96148be2a46ec445362661ef42bbaa96b2ee9091c747ad0
```

The image is named `identity.imageName`, which defaults to `identity.name` in
lowercase. The tag is derived from the definition, so a different definition
always produces a different tag. To get the reference without building, evaluate
it:

```sh
nix eval --raw .#billets.x86_64-linux.hello.ociImage.imageRefUnsafe
```

Alternatively, copy the image straight into the Docker daemon without an
intermediate archive:

```sh
nix run .#billets.x86_64-linux.hello.ociImage.copyToDockerDaemon
```

## Run the container

```sh
docker run --rm hello:7ded9d1e081f6d5cc96148be2a46ec445362661ef42bbaa96b2ee9091c747ad0
```

The image is configured from the definition:

| Image setting | Source                                   |
| ------------- | ---------------------------------------- |
| `Entrypoint`  | `process.package` + `process.executable` |
| `Cmd`         | `process.argv`                           |
| `Env`         | `process.environment`                    |
| `User`        | `process.user`                           |
| `WorkingDir`  | `process.workingDirectory`               |
| `StopSignal`  | `shutdown.stopSignal`                    |

`docker run` arguments after the image name replace `process.argv`, as with any
image.

Docker doesn't read the rest of the definition. Apply resources, ports, and
secrets with `docker run` options, for example:

```sh
docker run --rm \
  --cpus 1 --memory 64m \
  --publish 8080:8080 \
  --mount type=bind,source=./database,target=/run/secrets/database,readonly \
  hello:<tag>
```

Docker's own restart policy and health checks are also separate from the
definition's `restart` and `probes`. To have them honored without repeating
them, use a runtime that reads the manifest.

## Image contents

The image has a single layer containing the service's runtime closure, the same
store paths listed by `closureDescriptor`. It has no shell, package manager, or
base distribution. It also contains:

- `/etc/billet/manifest.json`: the canonical manifest.
- `/etc/billet/closure.json`: the closure descriptor.

These labels identify the image:

| Label                                               | Value                        |
| --------------------------------------------------- | ---------------------------- |
| `org.actionable-work.billet.manifest-digest`        | The Billet's manifest digest |
| `org.actionable-work.billet.system`                 | The Billet's system          |
| `org.actionable-work.billet.schema-version`         | `1`                          |
| `org.actionable-work.billet.oci-adapter-version`    | `1`                          |
| `org.actionable-work.billet.nix2container-revision` | The image builder revision   |

```sh
docker image inspect hello:<tag> \
  --format '{{index .Config.Labels "org.actionable-work.billet.manifest-digest"}}'
```

Builds are reproducible: the same definition and inputs produce byte-identical
images.

## Push to a registry

Set `identity.imageName` to include your registry:

```nix
identity = {
  name = "hello";
  version = "0.1.0";
  imageName = "registry.example.com/team/hello";
};
```

Then push the image under its own reference:

```sh
nix run .#billets.x86_64-linux.hello.ociImage.copyToRegistry
```

`ociImage` is a [nix2container](https://github.com/nlewo/nix2container) image,
so its other copy helpers work too. To push under a different name or tag, pass
any [Skopeo](https://github.com/containers/skopeo) destination to `copyTo`:

```sh
nix run .#billets.x86_64-linux.hello.ociImage.copyTo -- \
  docker://registry.example.com/hello:0.1.0
```

## Export an OCI image layout

`ociLayout` writes a standard OCI image layout, for tools that read images from
disk:

```sh
nix build .#billets.x86_64-linux.hello.ociLayout -o hello-oci
```

```text
hello-oci/
├── blobs/
├── index.json
├── oci-layout
├── image-digest     # the image manifest digest
└── provenance.json
```

`provenance.json` ties the image to the definition that produced it:

```json
{
  "adapter": "billet-oci",
  "adapterVersion": 1,
  "backend": "nix2container",
  "backendRevision": "42d1df94…",
  "billetManifestDigest": "sha256:e21c…",
  "closureDescriptorDigest": "sha256:0ac3…",
  "imageManifestDigest": "sha256:73ef…",
  "schemaVersion": 1,
  "system": "x86_64-linux"
}
```

## Outputs

| Attribute     | Description                                                                                         |
| ------------- | --------------------------------------------------------------------------------------------------- |
| `ociImage`    | The nix2container image, with `imageRefUnsafe`, `copyTo`, `copyToDockerDaemon`, and `copyToPodman`. |
| `ociLayout`   | An OCI image layout directory, plus `image-digest` and `provenance.json`.                           |
| `dockerImage` | A Docker archive that `docker load` accepts.                                                        |

## Troubleshooting

Image attributes fail at evaluation when a Billet can't be packaged:

| Error                                                           | Fix                                                     |
| --------------------------------------------------------------- | ------------------------------------------------------- |
| `UnsupportedImageSystem`                                        | Build with an `x86_64-linux` or `aarch64-linux` `pkgs`. |
| `UnsupportedImageUser`                                          | Set `process.user` to numeric `uid:gid`.                |
| `identity.imageName: must be a lowercase image repository name` | Set `identity.imageName` to a valid repository name.    |
