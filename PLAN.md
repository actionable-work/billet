# BI-P1: independent foundation

Owner: Taylor Hanken. Scope: public module schema, canonical IR, validator and
versioned transitive closure descriptor. Code-facing requirements live under
`.bloomery/specs/BILLET/`; implementation evidence belongs in docs/bi-p1.md.

1. Inspect local/remote state and authoritative inputs; bootstrap the public basic
   Bloomery template without modifying adjacent repositories.
2. Establish self-contained public contracts and source-ID traceability, then this
   bounded plan before implementation.
3. Implement Nix module evaluation, value-free diagnostics, effective defaults,
   canonical serialization and SHA-256 manifest identity. Export generic system API.
4. Produce descriptors using Nix's real transitive reference graph, with NAR identity
   and executable checks. Include primary/init/probe/config runtime roots.
5. Replace Rust greeting examples with an argument-safe Nix tool driver. Supply a
   runnable example and positive/negative acceptance fixtures tied to requirements.
6. Generate locks/health through Bloomery, format, run bloomery check and full
   nix flake check; inspect Jujutsu diff and record exact evidence/limitations.

Acceptance: repeat/order/default determinism, explicit old-version rejection,
invalid paths/types/policies, reference-only secret artifacts, multi-level closure
and independent public-only build checks. Only host-executed checks establish
execution evidence. No commit, push, scheduler, hosted deployment or runtime target.

Next slice BI-P2: Compose/OCI adapter and production-IR Bloomery lifecycle harness.
Implement or explicitly reject required semantics before claiming conformance.
Keep questions as repository-local handoffs; do not edit Platform or Bloomery.
