# Nix microVM artifact

The [bundle design](microvm-bundle.md) specifies the multi-guest artifact and
its native networking.

## Public artifacts

`mkBillet` exposes `microvm` for a single Billet. `capabilityReport` identifies
the versioned `microvm-artifact-v1` profile, selected system, manifest digest,
required capabilities, supported native mappings, and field-scoped diagnostics.
`configuration` is the guest's NixOS module settings. `file` writes those
settings as `microvm.json` for inspection and drops the Nix string contexts from
the serialized settings so the file can build independently of the guest.

Evaluate the guest with the supplied Linux package set and the pinned
MicroVM.nix guest module. `runner` selects MicroVM.nix's QEMU `declaredRunner`.
`bundle` contains the runner as `runner`, the exact standalone `microvm.json`,
and the canonical `manifest.json`. The closure descriptor validates the declared
executables before packaging. The stock MicroVM.nix runner consumes the guest
image, including its read-only store disk. The guest also exposes the exact
manifest at `/etc/billet/manifest.json`.

Preflight and configuration evaluation leave application derivations unrealized.
Error diagnostics gate configuration, file, runner, and bundle access. Warnings
allow rendering. Error messages identify the fields and reasons without
including rejected values. Eligibility is limited to x86_64-linux and
aarch64-linux with matching build and guest platforms, v1 IR, and representable
native settings.

## Guest service

Use one `billet.service` wanted by `multi-user.target`. Native systemd
directives set the executable and literal argument vector, ordinary environment,
numeric UID and GID, and working directory. Accept canonical decimal UID and GID
below 4294967295, excluding the reserved value 65535. Escape systemd
substitutions and encode unit words so empty arguments, whitespace, quotes,
shell syntax, dollar signs, and percent specifiers reach the process verbatim. A
working directory must be representable literally in a `WorkingDirectory=`
setting and must exist when the service starts.

Reuse the guest's account database entries for UID and GID values already in
use. Declare a system user or group for each missing ID so systemd can resolve
the numeric settings at boot.

## VM resources and shutdown

Use QEMU with KVM by default. The optional `microvm.acceleration = "tcg"`
selects software emulation on the same architecture. Use one vCPU per rounded-up
core of the declared CPU limit and cap the profile at 64 vCPUs. Round the
application memory limit up to MiB and add 512 MiB of guest overhead, with a
maximum application limit of 1 TiB. When that total is exactly 2048 MiB,
allocate 2049 MiB instead because QEMU hangs with exactly 2 GiB of guest memory.
Use systemd CPU and memory limits for the primary service, with a one-second CPU
quota period and a quota expressed to millicore precision. CPU and memory
requests remain available to the consumer in the manifest and each receives an
advisory.

Use systemd control-group cleanup, the declared stop signal, and the declared
grace period. A zero grace period uses a one-microsecond timeout because systemd
interprets zero as unlimited. Reject grace periods that overflow systemd's
microsecond duration when converted from seconds.

Load the guest input drivers needed by the stock runner's virtual power button.

## Consumer policy

The guest has no virtual network interface by default. The report advises when
the guest has port, private connection, or non-default egress declarations.
Initialization, probes, enabled restart, rollout, replica counts other than one,
scaling metrics, placement, strict singleton, storage claims, and secret
references remain policy declarations in the canonical manifest. Emit a warning
for each applicable field. The runtime owns orchestration and applying these
policies, including resolution and delivery of secret values. The generated
settings contain ordinary environment only. The supported capability list covers
the mapped resource limits, process-tree cleanup, and shutdown.

## Qualification

`tests/microvm.test.nix` compares the pure configuration and report using an
application package that fails if realized. Each numbered assertion binds the
matching `BILLET-IR-MICROVM` record. The standalone-file check builds and parses
the exact JSON settings with the same application package.

`tests/microvm-boot.test.nix` boots the packaged guest under QEMU software
emulation. Each number below refers to a `BILLET-IR-MICROVM` record.

| Records | Witness                                                                                                                    |
| ------- | -------------------------------------------------------------------------------------------------------------------------- |
| 041–043 | Byte comparisons for both files and the bundle's exact upstream runner symlink.                                            |
| 044     | The packaged runner starts the guest and the declared executable reports readiness after its assertions.                   |
| 045–049 | Separate guest assertions check every argument, the environment value, the working directory, and the numeric UID and GID. |
| 050     | The guest reads a transitive data file through a store path retained by ordinary environment.                              |
| 051–052 | The guest reads its own cgroup's CPU quota and memory limit from the kernel.                                               |
| 053     | The digest of the guest's manifest matches the canonical digest from outside the guest.                                    |
| 054     | The service receives the declared signal and reports it during shutdown via the packaged MicroVM.nix shutdown command.     |
