# Runtime closure descriptor v1

`closureDescriptor` is a derivation producing `descriptor.json`, `manifest.json`
and `store-paths`. The descriptor contains `schemaVersion=1`, selected `system`,
`manifestDigest`, sorted unique `roots`, and path-sorted `paths`. Each path record
contains `path`, `narHash` (Nix SHA-256 NAR identity), positive `narSize`, and sorted
unique direct `references`. Root set includes the primary package, initialization
packages and exec-probe packages. It also includes store dependencies carried by
non-secret configuration string contexts, so working directories, environment and
argv may reference immutable runtime data, through an immutable manifest root.
Secret references must have no store
context. Every root and every transitive reference appears exactly once; unrelated
host-store objects and build-only dependencies do not belong to the set.

Use Nix's structured `exportReferencesGraph` over realized roots for authoritative
closure metadata. Do not infer closure from direct dependencies or derivations.
Check executable existence, containment and permission after realization. Bind
metadata to canonical manifest digest and system. Descriptors contain no secret
values. Descriptor presence is not a signature, independent integrity verification,
runtime admission, store isolation or a VM conformance result. Consumers must reject
unknown descriptor/schema versions and independently verify retrieved NAR bytes.
