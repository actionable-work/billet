# Billet CLI

`billet validate INSTALLABLE` invokes `nix eval --json INSTALLABLE.ir`.
`billet manifest INSTALLABLE` invokes `nix eval --raw INSTALLABLE.canonicalJSON`.
`billet closure INSTALLABLE` invokes `nix build --no-link --print-out-paths
INSTALLABLE.closureDescriptor`. Exactly one explicit installable is required;
reject options in its position. Use process argument arrays, never a shell.
Propagate child exit code; command launch failures and invalid usage fail clearly.
Use the Nix library for module evaluation, not a parallel Rust schema.
