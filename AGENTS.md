# Billet development

## Repository scope

Billet evaluates declared Nix modules into a canonical application IR and
generates artifacts from that IR. Target families are Docker images, Docker
Compose, Kubernetes, Nix microVM, and Hammerworks-native manifests. Work on an
individual target only when requested.

In scope are IR normalization and validation, closure and image construction,
target-specific rendering and packaging, renderer diagnostics, artifact-only
CLI commands, and automated checks that validate artifacts with their consumers.
Carry declarative lifecycle and policy intent into the runtime-facing manifests
and preserve public reference metadata.

Runtime implementation is out of scope. The consuming runtime owns deployment,
reconciliation, application execution and supervision, readiness and health
decisions, restart, shutdown, rollout and rollback, admission, network and
resource enforcement, and resolving or delivering secret values. Avoid adding
controllers, runners, proxies, runtime state stores or deploy/control commands
here. Test fixtures may invoke the actual artifact consumer in isolation.

## Development workflow

Use the code-facing specifications in `.bloomery/specs/BILLET/`. Write design,
then bounded root PLAN.md, then implementation. Keep progress/evidence in docs.
Write fine-grained Bloomery requirements: one independently verifiable behavior
per record, with an explicit condition/outcome, source BI lineage, and a precise
owning design reference. Link automated records to tests that actually assert the
behavior; document the witness when a check covers several records. Prefer
executable qualification, including isolated Linux/Docker VM checks for live
behavior, over manual records. Use manual qualification only when no adequate
automated witness is available, and state that limitation explicitly. Keep
diagnostic smoke runs, static trace bindings and actually executed automated
qualification distinct. Do not use umbrella records or passing check counts as
substitutes for granular specifications.
Preserve existing requirement IDs; add atomic records without recycling or
silently narrowing old IDs.

Preserve BI source IDs and public/private boundaries. Never pass secret values to
Nix; use runtime references only. One Billet has one primary application.

Use `nix develop --command <command> ...` for each tool invocation; do not keep a
running shell. Run Bloomery natively inside that environment: `bloomery sync`
after dependency/layout changes, `bloomery check`, `nix fmt`, `nix flake check`.
Prefer Bloomery CLI for spec records. Generate lock/health artifacts with their
owning tools. Investigate retained failures; do not substitute native Cargo checks.
Use `jj status` / `jj diff` to inspect changes. Stage task files for Git-backed Nix
source visibility. Use Conventional Commit messages. Do not commit or push unless requested. Keep adjacent work intact.

Prefer Rust for repository tooling and acceptance harnesses. Use pinned nix2container
for container image construction; keep service evaluation in Nix.

Keep integration checks, fixtures and smoke app wiring in `tests/flake.nix`,
registered by `[flakes.tests]` in `.bloomery/config.toml`. Use Bloomery's subflake
composition instead of adding test definitions to the root flake.
