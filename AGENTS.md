# Billet development

Use the code-facing specifications in `.bloomery/specs/BILLET/`. Write design,
then bounded root PLAN.md, then implementation. Keep progress/evidence in docs.
Preserve BI source IDs and public/private boundaries. Never pass secret values to
Nix; use runtime references only. One Billet has one primary application.

Use `nix develop --command <command> ...` for each tool invocation; do not keep a
running shell. Run Bloomery natively inside that environment: `bloomery sync`
after dependency/layout changes, `bloomery check`, `nix fmt`, `nix flake check`.
Prefer Bloomery CLI for spec records. Generate lock/health artifacts with their
owning tools. Investigate retained failures; do not substitute native Cargo checks.
Use `jj status` / `jj diff` to inspect changes. Stage task files for Git-backed Nix
source visibility. Do not commit or push unless requested. Keep adjacent work intact.
