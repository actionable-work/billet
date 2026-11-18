# Bloomery integration and flake boundaries

The public Billet flake exports `lib.mkBillet` and `lib.mkBilletBundle` and pins `nixpkgs` and `nix2container`. Application flakes choose their own supported systems and supply the package set to Billet. Application examples and qualification run through independent subflakes. The public root has no input edge to any of them.

Each evaluated service exposes `validationCheck`. Its derivation evaluates the complete normalized IR and writes a result without realizing application packages. Each bundle exposes the same attribute. Bundle validation checks that the member set is nonempty, validates each member's IR, and checks member identity and system. Target eligibility, artifact construction, and runtime qualification have separate entry points.

A Bloomery application passes `billets = { pkgs, packages }: ...` to `mkFlake`. The function returns a named set of evaluated Billets and bundles. Bloomery publishes the set for each configured system and registers each `validationCheck` as `billet:<name>:validate`. The application selects the `billet` input and the desired packages. Both inputs can follow the application's `nixpkgs` pin.

The `tests` subflake owns qualification, including the Rust acceptance harness and the artifact CLI fixture. Its requirements and witnesses are evaluated with Bloomery from there. The example subflakes own their inputs and outputs. `hello` consumes Billet directly, and `catalog-report` consumes Billet and Bloomery as siblings and exports both services and their Compose bundle.

`BILLET-PUBLIC-BUILD-004` previously required the tests subflake to be
registered through the root's Bloomery configuration. With Bloomery removed
from the public root, it was deliberately re-scoped to verify direct
qualification subflake outputs; root registration is no longer a requirement.
`BILLET-IR-TARGETS-022` verifies the hello subflake's default app at its
standalone entry point. Both requirements retain their source BI lineage.

## Qualification evidence

| Check | Witness |
| --- | --- |
| Bloomery `billet:output-contract` | Two systems receive their selected package sets and expose the named service and bundle. Ordinary and added checks remain available, and omitting the callback retains the existing extension path. |
| Bloomery `billet:invalid-outputs` | Evaluation fails for a malformed callback result, missing or invalid validation derivations, a generated check name collision, and competing Billet outputs. |
| Billet `billet:public-flake` | The root and its lock declare only the public inputs, the root exports only the library, and qualification and smoke outputs live in the test flake. |
| Billet `billet:validate-service` | An invalid IR fails evaluation. The check writes a valid service's manifest digest even when realizing its package would fail. |
| Billet `billet:validate-bundle` | Empty members, mismatched identities or systems, and invalid member IR fail validation. A structurally valid bundle with an ineligible Compose user still writes the named manifest digests. |
| Billet `billet:public-format` | Alejandra formatting holds for the root flake, the public library, and the hello example, which the test flake's own formatter does not cover. |
| Billet `billet:ci-app` | The exported `apps.<system>.ci` runs the enclosing checkout's `tests/ci.sh` from a nested directory and fails outside a checkout. `nix run ../../tests#ci` from `examples/hello` passed the full CI run (49 test and 15 catalog Bloomery checks). |
| Billet `billet:catalog-validation` | The catalog example exports two service entries and their bundle. Each named Bloomery check builds the matching validation derivation. |
| Billet `billet:compose-artifact` | The isolated Docker VM verifies manifest and image identities, the Bloomery-built catalog entrypoint, and the inventory that the report receives over the Compose network. |

On x86_64-linux, `tests/ci.sh` passed with the public pins and the local
Bloomery implementation. It ran `nix flake check` for the root, the test
subflake, and both examples. The local override also ran the catalog and
test flake suites through the native callback. The pinned qualification and
catalog Bloomery runs were `r335a69-18e93f88d5cde353-0` and
`r335bb3-18e93f897039e252-0`. The Docker VM was built and run by
`vm-test-run-billet-compose-artifact.drv` and later checks reused that result.

In the Bloomery repository, `nix flake check` and the development CLI's
`check --no-write` passed. The native Bloomery run was
`r333fda-18e93f53fe8f0078-0`.

All declared systems evaluated for the Billet test and example flakes. Both
new Bloomery checks evaluated on aarch64-linux and aarch64-darwin. The wider
Bloomery all-system evaluation encountered LLVM store path errors and the
removed Darwin SDK shim in existing checks. The same errors reproduced at
the unchanged Bloomery revision `529e753`.

The first runs above used a Bloomery pin (`529e753`) that predated the native
callback, so the catalog example carried a temporary compatibility adapter.
The test and catalog locks now pin the published Bloomery `dbbd6fe`, which
provides `mkFlake.billets`. The adapter was removed, and the catalog example
passes `billets` to `mkFlake` directly. With those pins, `nix run ./tests#ci`
passed: `nix flake check` for the root, both examples and the test flake,
and Bloomery runs of 49 test checks and 15 catalog checks.
