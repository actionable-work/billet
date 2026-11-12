# BI-P1 implementation and verification

Implemented November 10–11, 2026. Accountable owner: Taylor Hanken.
The archived [plan](plans/bi-p1.md) followed public contract authoring before code.
This is implementation evidence; normative requirements remain in
[repository specifications](../.bloomery/specs/BILLET/README.md).

## Delivered

- Public `lib.mkBillet` using `lib.evalModules`, with one primary process and
  declarations for resources, initialization, health, lifecycle, network, runtime
  secret references and storage. Hosted system restrictions remain consumer policy.
- IR schema/normalization v1, explicit effective defaults, canonical JSON and
  SHA-256 identity. Unknown schemas and invalid definitions fail with field paths.
- Closure descriptor v1 built from Nix's structured transitive reference graph,
  bound to system/manifest and carrying NAR hash, size and direct references.
  Primary, init, probe and configuration dependencies are retained. Executables
  must exist, be executable regular files and resolve inside their package output.
- A thin Rust CLI invoking Nix without a shell, a runnable hello example,
  portable golden IR, invalid fixtures, complete closure fixtures and dual licenses.

## Reproducible validation

All commands ran from the repository root using direct `nix develop --command`
invocations. No persistent development shell is required.

| Command | Result |
| --- | --- |
| `nix develop --command bloomery sync` | Generated Cargo.lock and bloomery.lock after crate changes. No external Rust dependencies. |
| `nix develop --command nix fmt` | Passed; full flake checks also verified formatting. |
| `nix develop --command bloomery check` | **32 checks passed**. Final run `rc24c3-18e72d4364d92466-0`. |
| `nix develop --command nix flake check` | **Passed on x86_64-linux**, including expected-failure executable cases. Other systems were explicitly omitted from execution. |
| `nix develop --command nix run . -- validate .#billets.x86_64-linux.hello` | Produced normalized v1 IR. |
| `nix develop --command nix run . -- closure .#billets.x86_64-linux.hello` | Built descriptor output successfully. |
| `nix develop --command nix run .#example -- '--greeting=Hello from Billet'` | Printed `Hello from Billet`. |
| `nix develop --command nix eval --json .#billets.aarch64-linux.hello.ir.system` | Returned `"aarch64-linux"`; evaluation only. |

Bloomery generated the retained health baseline with workspace/crate scores 100.
Full logs are retrievable locally through Bloomery's run/details/health commands.
The public locks pin Bloomery `dda68d90d7e035b10b7d027c6fbf531296e9c516`
and nixpkgs `4975466d324710c576dc11ad614684e6bd8cad8e`.
Toolchain: Bloomery 0.1.0, rustc 1.98.1, Nix 2.35.2
(Determinate Nix 3.22.2). All locked flake nodes use public GitHub inputs.

## Acceptance evidence

- Two independent evaluator processes produce identical canonical bytes.
  Omitted/explicit defaults, reordered/deduplicated set-like declarations,
  ordered argv with empty/metacharacter arguments and the v1 golden agree.
- Invalid fixtures reject unknown/multiple-application fields, old schemas,
  types, systems, bad executable paths, resource/probe limits, duplicate ports,
  mount overlaps, secret collisions, init budgets, retry/shutdown/rollout settings,
  and overflowing aggregate scratch budgets. Seven subprocess diagnostic fixtures
  assert field paths and absence of the rejection canary.
- Secret references survive normalization without any value field. Tests inspect
  manifest, descriptor and actual derivation input attributes for canary absence;
  context-bearing secret bindings are rejected. No secret resolver is invoked.
- Five expected build failures cover missing primary/init/probe executables,
  symlink escape and non-executable files, asserting the owning field diagnostic.
- The multi-level closure fixture verified **18 runtime paths**: separate primary,
  initialization and probe packages; app → intermediate → leaf; and configuration
  dependencies. All roots/references are reachable and unique, with no unrelated
  package. Tests dump actual NAR bytes and independently compare every hash/size.
- Compiled CLI tests preserve a hostile-looking installable as one argument and
  propagate child exit 37; invalid usage and missing Nix fail predictably.
- The minimal hello descriptor contains **6 paths**, **2 roots** and **37,999,112
  NAR bytes**. Its canonical manifest digest is
  `sha256:ccd2f7bebe0716db85cf6c7c9645a587df9a3588d0dea0adca862b9c2db6634e`.

Earlier failures were investigated through retained Bloomery evidence. Nix list
expressions were corrected; nested diagnostic evaluation uses a dummy store to
avoid initializing host Nix state inside a sandbox. No Cargo validation replaced
Bloomery. The final flake run emits an upstream formatter-option rename notice
and notes custom flake outputs as unchecked; explicit Billet checks exercise them.

## Scope and remaining gates

BI-P1 supplies declarations and metadata, not runtime enforcement. Compose/OCI,
target capability negotiation, runtime secret delivery, bounded lifecycle/rollout
execution, storage cleanup and policy enforcement remain BI-P2. No scheduler,
hosted deployment, Lineshaft, MicroVM or Kubernetes target was added.

Only x86_64-linux has build/execution evidence. aarch64-linux evaluation does not
qualify its runtime or Darwin. No clean-machine cache substitution, signature trust,
isolated guest store, full BI010 semantic diff/migration suite or target runtime
conformance is claimed. Descriptor consumers must verify NAR bytes and authority
independently. The module language/non-secret literals are trusted public inputs;
arbitrary Nix code is not a sandbox for values mistakenly supplied as secrets.

[Traceability](traceability.md) records requirement coverage. The
[next Compose slice and interface handoffs](handoffs.md) preserve the remaining
capability-specific gates. The adjacent Platform and Bloomery checkouts were
read only. The verified foundation was subsequently committed as
`bc181d4f112e83a6498107e48749989af9607a4e` with message
`feat: add Billet schema, canonical IR and closure tooling`. No push was performed.
