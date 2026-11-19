# Billet CLI

The Rust command is a qualification fixture in the tests flake. Its public
artifact operations are available directly through the Nix selectors below.

`billet validate INSTALLABLE` invokes `nix eval --json INSTALLABLE.ir`.
`billet manifest INSTALLABLE` invokes
`nix eval --raw INSTALLABLE.canonicalJSON`. `billet closure INSTALLABLE` invokes
`nix build --no-link --print-out-paths INSTALLABLE.closureDescriptor`.
`billet image INSTALLABLE` builds `INSTALLABLE.ociImage` with the same build
flags. `billet layout INSTALLABLE` builds `INSTALLABLE.ociLayout` with the same
build flags. `billet compose INSTALLABLE` builds
`INSTALLABLE.dockerCompose.bundle` with the same flags and prints its store
path. `billet capabilities INSTALLABLE` evaluates
`INSTALLABLE.dockerCompose.capabilityReport` as JSON. The report describes
artifact eligibility, native Compose mappings, and mapping advisories. It
preserves the IR's capability requirements. Exactly one explicit installable is
required; reject options in its position. Use process argument arrays, never a
shell. Propagate child exit code; command launch failures and invalid usage fail
clearly. Use the Nix library for module evaluation, not a parallel Rust schema.
