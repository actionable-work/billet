# Library functions

The Billet flake exports its library as `billet.lib`. It has two functions:
`mkBillet` defines one service, and `mkBilletBundle` groups several.

## `mkBillet`

Evaluates one application definition.

```nix
billet.lib.mkBillet {
  pkgs = nixpkgs.legacyPackages.${system};
  modules = [ ./application.nix ];
}
```

### Arguments

| Argument  | Description                                                                                                                 |
| --------- | --------------------------------------------------------------------------------------------------------------------------- |
| `pkgs`    | The package set for the target system. Its host platform selects the Billet's system.                                       |
| `modules` | A list of Nix modules evaluated with `lib.evalModules`. Each module receives `pkgs`. See [Application modules](modules.md). |

Modules merge like NixOS modules, so you can share defaults across services:

```nix
let
  defaults = {
    resources = {
      cpuRequest = 100; cpuLimit = 1000;
      memoryRequest = 16777216; memoryLimit = 67108864;
    };
  };
in billet.lib.mkBillet {
  inherit pkgs;
  modules = [ defaults ./catalog.nix ];
}
```

Invalid definitions fail at evaluation with the field path and a reason. Error
messages never echo the rejected value.

### Definition attributes

| Attribute         | Type       | Description                                                                    |
| ----------------- | ---------- | ------------------------------------------------------------------------------ |
| `ir`              | Nix value  | The normalized application definition, with every IR default made explicit.    |
| `canonicalJSON`   | string     | The IR as canonical JSON: sorted keys, no whitespace.                          |
| `manifestDigest`  | string     | `sha256:<hex>` of `canonicalJSON`. It identifies the definition.               |
| `manifest`        | derivation | A file containing `canonicalJSON`.                                             |
| `validationCheck` | derivation | Evaluates the full IR and writes the manifest digest. Does not build packages. |

The IR also records the selected `system` and `requiredCapabilities`: the
runtime capabilities the definition depends on, such as `probes`,
`runtime-secrets`, or `storage-persistent-disk`. A runtime uses this list to
decide whether it can admit the service.

### Closure attributes

| Attribute           | Type            | Description                                                                        |
| ------------------- | --------------- | ---------------------------------------------------------------------------------- |
| `runtimeRoots`      | list of strings | Store paths of the process, initialization, and probe packages, plus the manifest. |
| `closureDescriptor` | derivation      | The complete runtime closure of those roots.                                       |

The closure descriptor directory contains:

- `descriptor.json`: every transitive runtime store path with its NAR hash, NAR
  size, and direct references.
- `manifest.json`: the canonical manifest.
- `store-paths`: the store paths, one per line.

Building the descriptor checks that every declared executable exists, is an
executable regular file, and resolves inside its package.

### Runtime attributes

Each runtime's artifacts are described in its guide.

| Attribute                                                               | Guide                                        |
| ----------------------------------------------------------------------- | -------------------------------------------- |
| `ociImage`, `ociLayout`, `dockerImage`                                  | [Docker](runtimes/docker.md)                 |
| `dockerCompose` (`capabilityReport`, `configuration`, `file`, `bundle`) | [Docker Compose](runtimes/docker-compose.md) |

## `mkBilletBundle`

Groups several Billets so they deploy together.

```nix
billet.lib.mkBilletBundle {
  inherit pkgs;
  billets = { inherit catalog report; };
}
```

### Arguments

| Argument  | Description                                                                                        |
| --------- | -------------------------------------------------------------------------------------------------- |
| `pkgs`    | The package set shared by every member.                                                            |
| `billets` | A non-empty attribute set of `mkBillet` results. Each key must match the member's `identity.name`. |

Every member must use the same system as `pkgs`.

### Attributes

| Attribute         | Description                                                                                              |
| ----------------- | -------------------------------------------------------------------------------------------------------- |
| `billets`         | The member Billets.                                                                                      |
| `validationCheck` | Validates every member and the bundle structure, then writes each member's manifest digest.              |
| `dockerCompose`   | One Compose project with a service per member. See [Docker Compose](runtimes/docker-compose.md#bundles). |

`validationCheck` rejects an empty bundle and identifies members with mismatched
keys or systems.
