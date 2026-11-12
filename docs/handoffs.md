# Interface handoffs and next Compose slice

## BI-P2: Compose/OCI and Bloomery harness

The OCI artifact (via pinned nix2container) and pure `compose-foundation-v1` rejection profile are implemented
in BI-P2.01. That profile has no qualified runtime capabilities and produces no
Compose configuration. The remaining work below requires a real lifecycle adapter.

Consume the v1 IR and descriptor without defining a second schema. Begin with a
single application container/replica and an OCI closure adapter. Report required
capabilities before image construction. Use an explicit supported profile and
reject every unimplemented requirement with a field path; do not claim that a
Compose YAML file enforces lifecycle, policy or cleanup.

The production-IR harness must prove argv handling, startup/readiness/liveness,
ordered initialization before every start, bounded durable retries, complete-tree
shutdown and intentional-stop restart suppression. Add hard CPU/memory/storage
bounds, ephemeral cleanup and reference-only runtime secret injection. Conformance
must also address rollout surge/availability, continuous readiness, deadlines and
one bounded rollback with exact old non-secret config/current authorized bindings.
A first bounded adapter may explicitly reject policies it cannot enforce; default
lifecycle policies are required too. Plain Compose restart policies cannot claim
this contract. Networking policy, persistent storage and unsupported scaling need
separate support or explicit errors. Keep live engine tests opt-in until the
runner environment is declared; retain actual runtime evidence per capability.

## Consumer integration questions

- Confirm the first consumer's accepted descriptor/schema versions, NAR identity
  spelling and current-binding resolver API. Public v1 metadata is not a cache
  signature, trusted-producer claim or deployment authorization.
- Hammerworks' initial hosted profile must reject systems other than x86_64-linux
  before build/image preparation. Standalone mkBillet retains the supplied pkgs
  system. Keep that admission profile in the consuming adapter.
- Choose the durable restart/rollout state owner for the Compose harness before
  claiming BI015–BI021. Define episode/start IDs and cleanup authority there.
- OCI artifact v1 uses the exact closure store paths and numeric uid:gid mapping.
  Qualify runtime user permissions and supported termination signals in the target;
  preserve package-relative executable containment and all descriptor roots.

These are local handoffs only; adjacent repositories were not modified.

## Bloomery bootstrap observation

Public revision dda68d90d7e035b10b7d027c6fbf531296e9c516 provides the supported
mkFlake extraOutputs callback; its checks merge additively. The basic template
contains Rust greeting examples, which Billet replaces with its Nix tool driver.
`spec add` refuses an empty feature without an existing requirement group, while
`spec remove` refuses removal of the final group. Initial Billet records were
seeded in the documented format and validated by `spec list` and `check`; further
record edits can use the CLI. No Bloomery changes are required by this build.
