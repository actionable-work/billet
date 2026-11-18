# Docker and Compose artifact qualification

The artifact profile replaces the historical foundation preflight. It preserves
the existing target requirement IDs and records their revised artifact scope.
The normalized IR still carries lifecycle declarations for the consuming runtime.
The active repository history builds on the original OCI artifact slice.

| Requirement | Automated witness |
| --- | --- |
| TARGETS-001 | Preflight checks the versioned artifact profile and redacted image diagnostics. |
| TARGETS-002 | A valid profile renders a Compose file for a fixture whose package would fail if realized. |
| TARGETS-003 | The capability report echoes the exact IR-required list and claims no runtime capabilities. |
| TARGETS-004 | The preflight rejects an invalid user with the owning field and without a credential value. |
| TARGETS-005 | Preflight covers ARM64 eligibility, unsupported systems, a mismatched package set and a nonnumeric user. |
| TARGETS-006 | The VM checks the exact precomputed image reference in the Compose configuration. |
| TARGETS-007 | The rendered extension carries the canonical filename and digest. |
| TARGETS-008 | The bundled manifest is byte-identical to the canonical one and retains rollout and reference metadata. |
| TARGETS-009 | Docker loads the archive under the Compose reference and preserves the image manifest label. |
| TARGETS-010 | Docker Compose parses the file and runs the declared primary process with the bundled image. |
| TARGETS-011 | The VM checks the exact service fields and observes the image-provided entrypoint and argv. |
| TARGETS-012 | The parsed Compose configuration contains one service named for the canonical application identity. |
| TARGETS-013 | The VM verifies that Compose preserves the `never` pull policy. |
| INVOCATION-007 | The Rust CLI unit checks the build command and `dockerCompose.bundle` selection. |

The test subflake owns the preflight, image and Compose acceptance checks.
The root composes them through Bloomery and retains the independent Rust CLI,
IR and closure tests. The static trace includes 85 bound requirements and zero
manual records.

The first no-write run `r109388-18e904ee87a3ee4a-0` passed 40 checks. The Docker
archive export tried to stage a layer in `/var/tmp`, which is absent in the Nix
build sandbox. The exporter now passes the builder's temporary directory to
the pinned copy helper. The first run did not reach the Compose VM.

No-write run `r1112b2-18e905152de6ffdd-0` passed all 41 checks on x86_64-linux.
The Docker VM loaded the archive, validated the file with Compose 5.5.1, and
ran `hello` to completion with `Hello from Billet` in its output. The composed
container was removed by the fixture. The VM derivation was
`/nix/store/49q93zr94f85qdviqdndi5bz2n8yi2c4-vm-test-run-billet-compose-artifact.drv`.
The public `billet compose` command separately built the default example.
Bloomery updated the workspace code-health baseline to 94.91 from the passing
full run.

The normal Bloomery run `r112afd-18e90538f192f020-0` passed all 42 checks.
Both `nix flake check` and `nix flake check ./tests` passed on x86_64-linux and
reused the passing Compose VM derivation.

## Catalog and report example

The Docker VM exercises `billets.<system>.catalog-report.dockerCompose.bundle`. It checks that
each archive loads under the corresponding Compose reference (TARGETS-014),
that each image label matches the digest of its bundled manifest (TARGETS-015),
and that the report prints the inventory fetched from the catalog over the
Compose network (TARGETS-016).

The first run `r2f8672-18e933dfec73aa36-0` logged the expected JSON in the VM
and exited successfully from Compose. The assertion failed while parsing the
output of a second command that read the stopped container's logs. The test
now checks the attached `compose up` output directly.

Bloomery run `r2f9bbb-18e93407cfb05d5d-0` passed all 42 checks on x86_64-linux.
The Docker VM loaded both images, verified their manifest identities, and
observed the report print the catalog response before exiting successfully.

The bundle shares the individual Billet's `dockerCompose` selectors
(TARGETS-017). Artifact preflight checks wrong member keys (TARGETS-018),
different member systems (TARGETS-019), empty bundles (TARGETS-020), and
member-specific diagnostic propagation (TARGETS-021).

Bloomery run `r2fc934-18e9347a622bea3d-0` passed all 42 checks on x86_64-linux
after the bundle moved under `billets`. Both flake checks passed with the
Docker VM and bundle preflight enabled. The public Nix selector and
`billet compose` command produced the same bundle store path.

## Bloomery example subflakes

The example output check verifies that Bloomery composes the hello app
with the executable selected by its Billet (TARGETS-022) and that the
catalog Billet selects the Rust workspace package elevated by Bloomery
(TARGETS-023). The Docker VM asserts that the catalog image's entrypoint
is that package's `bin/catalog` (TARGETS-024), then the report fetches and
prints the inventory over the Compose network (TARGETS-016).

Root Bloomery run `r3013a0-18e9351584090107-0` passed all 52 checks. The
catalog-report workspace run `r300806-18e935092cb43e88-0` passed all 12.
The root, both examples, and the test subflake passed `nix flake check`
on x86_64-linux. Direct and root builds of each example returned identical
bundle paths. The Billet CLI also built the catalog-report subflake's bundle.
