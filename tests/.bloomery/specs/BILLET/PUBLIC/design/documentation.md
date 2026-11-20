# Documentation command qualification

Every shell command in `README.md` and `docs/` is either executed by an
automated scenario or carries an explicit reason for not being executed. The
qualification runs the documented text itself, so a renamed attribute, a stale
image tag, or a missing setup step fails a check.

## Annotations

An HTML comment as the last nonblank line above a fenced block names it:
`<!-- doctest: <id> -->`. Identifiers are unique across the documentation. A
block that cannot run in isolation uses `<!-- doctest: skip <reason> -->`
instead, and the reason must be nonempty. Rendered Markdown hides the comments.

Every `sh` block must have an annotation. Other blocks are named only when a
scenario uses them as input, for example an application module or flake that a
guide asks the reader to write. Text and output listings are not executed.

The test subflake parses the Markdown at evaluation time. A coverage check
rejects an unannotated shell block, an annotation that is not followed by a
fence, a duplicate identifier, an empty skip reason, a named block that no
scenario uses, a block that several scenarios use, and a scenario step that
names a missing block.

## Scenarios

A scenario lists the documentation blocks it runs, in document order, and the
harness steps that a guide states in prose, such as creating a namespace the
guide says must exist or writing a secret file the guide says to provide. It
runs all its steps in one Bash session with `errexit`, `nounset` and `pipefail`,
the way a reader runs them in one terminal, so shell variables and `result`
links carry from one block to the next. Harness assertions read the session
output after the documented commands finish.

A scenario whose last documented command keeps running, such as a foreground
Compose project or guest console, declares the output that proves success. The
session runner stops the whole process group after that output appears and fails
when the session exits or times out first.

Scenarios run where their consumer exists: Docker and Compose in a NixOS VM with
the Docker daemon and Compose plugin, Kubernetes in a NixOS VM with K3s, and
microVM guests in the build sandbox under QEMU software emulation. Commands that
only use Nix run in the build sandbox. Doc commands name `x86_64-linux`, so the
scenarios run only on that system.

## Nix stand-in

Nix cannot run inside the build sandbox or test VMs, so scenarios put a stand-in
`nix` program first on `PATH`. Before the scenario runs, evaluation extracts
each `<flake>#<attribute>` reference from the scenario's blocks and resolves it
against the flake the scenario declares for that directory. The flake outputs
come from the same expressions that the examples and guides define. Guide
projects are materialized from their named blocks, with the `billet` input bound
to the checkout under test. Each resolved derivation becomes a build dependency
of the scenario, so a missing attribute or a failing build fails the check
before any command runs.

The stand-in reads the resolved table and supports the documented forms:

- `nix build [-o|--out-link <link>] [--no-link] <ref>` replaces the link,
  `result` by default, with the derivation output.
- `nix eval --json <ref>` prints the value as JSON and `nix eval --raw <ref>`
  prints a string or a derivation output path.
- `nix run <ref> [-- <args>...]` executes the derivation's main program.
- `nix flake check` succeeds when the working directory's flake has resolved
  checks, which are all built as scenario dependencies.

It resolves a reference relative to the working directory of the process. It
rejects any other subcommand, option, or reference with an error naming the
unsupported form. This exercises the documented attribute paths, options and
output links with real artifacts, but not the Nix CLI's own flake fetching or
locking. `tests/ci.sh` covers the real CLI for the root, test and example
flakes.

## Exclusions

Commands that publish to an external registry or require a reader's own
workspace carry skip annotations. The corresponding manual records state the
limitation. `tests/ci.sh` runs `bloomery check` in the catalog-report workspace,
the same command the Bloomery guide documents for a reader's workspace.

## Qualification

`tests/docs.test.nix` defines the coverage check and the scenarios. The
`billet-doctest` Rust package implements the stand-in and the session runner,
and its unit tests cover argument handling. Each scenario check binds the
records for the guide it executes.
