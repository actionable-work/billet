# Bloomery integration

[Bloomery](https://github.com/actionable-work/bloomery) builds Rust workspaces
with Nix. Its `mkFlake` accepts a `billets` function, so services built from
your workspace can be published as Billets alongside the packages.

## Flake

Add Billet and Bloomery as sibling inputs:

```nix
{
  inputs = {
    billet = {
      url = "github:actionable-work/billet";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    bloomery.url = "github:actionable-work/bloomery";
    nixpkgs.follows = "bloomery/nixpkgs";
  };

  outputs = { billet, bloomery, nixpkgs, ... }:
    bloomery.mkFlake {
      inherit nixpkgs;
      root = ./.;
      billets = import ./billets.nix { billetLib = billet.lib; };
    };
}
```

## Billet definitions

The `billets` function receives `{ pkgs, packages }` for each system, where
`packages` holds the workspace packages that Bloomery builds. It returns a named
set of Billets and bundles:

```nix
# billets.nix
{ billetLib }: { pkgs, packages }: let
  catalog = billetLib.mkBillet {
    inherit pkgs;
    modules = [{
      identity = { name = "catalog"; version = packages.catalog.version; };
      process = { package = packages.catalog; executable = "bin/catalog"; };
      network.ports.http = { port = 8080; protocol = "http"; };
      resources = {
        cpuRequest = 100; cpuLimit = 1000;
        memoryRequest = 16777216; memoryLimit = 67108864;
      };
    }];
  };
in {
  inherit catalog;
  stack = billetLib.mkBilletBundle {
    inherit pkgs;
    billets = { inherit catalog; };
  };
}
```

## What Bloomery publishes

For each configured system, Bloomery:

- exposes each entry at `billets.<system>.<name>`, and
- registers each entry's `validationCheck` as the check
  `billet:<name>:validate`.

`nix flake check` and `bloomery check` then validate every definition without
building images.

```sh
nix develop --command bloomery check
nix build .#billets.x86_64-linux.stack.dockerCompose.bundle
```

See the [catalog-report example](../examples/catalog-report) for a complete
workspace with two services.
