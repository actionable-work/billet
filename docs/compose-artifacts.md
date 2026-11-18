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
