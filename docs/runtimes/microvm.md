# Nix microVM

Billet builds one NixOS guest per application using the pinned MicroVM.nix QEMU
backend. The profile supports `x86_64-linux` and `aarch64-linux` with matching
build and guest platforms. Running the default artifact requires KVM on the
host. Set `microvm.acceleration = "tcg"` in the application module for software
emulation on the same architecture.

## Inspect and build

From the Billet repository, use the hello example to inspect and build the
artifact. Substitute `aarch64-linux` when building on that platform.

<!-- doctest: microvm-build -->

```sh
nix eval --json ./examples/hello#billets.x86_64-linux.hello.microvm.capabilityReport
nix build ./examples/hello#billets.x86_64-linux.hello.microvm.bundle
```

The resulting `result/` directory contains `runner/`, `microvm.json`, and
`manifest.json`. `runner/bin/microvm-run` is the MicroVM.nix launch program. Use
a writable working directory per guest instance for its local control socket.
MicroVM.nix also provides `runner/bin/microvm-shutdown`.

`microvm.configuration` exposes the NixOS module settings. `microvm.file` builds
their JSON representation independently of the guest. `microvm.runner` builds
the native MicroVM.nix runner directly. The guest exposes the canonical manifest
at `/etc/billet/manifest.json` and contains the application closure on a
read-only store disk.

## Bundles

`mkBilletBundle` packages `microvm.json`, `guests/<service>/runner`, and
`manifests/<service>.json`. Member names must be lowercase DNS labels starting
with a letter. Use declared private connections for guest-to-guest access. The
bundle maps each local destination through a TCP listener on `127.0.0.1` and
gives source guests the destination's service alias. Host ports start at
`microvm.hostPortBase`, which defaults to `18080`. Choose a free port range on
the host when building. Restrictive egress on a connected guest requires
consumer-provided networking.

The catalog-report example uses TCG. Build the complete bundle from the
repository root.

<!-- doctest: microvm-bundle -->

```sh
nix build ./examples/catalog-report#billets.x86_64-linux.catalog-report.microvm.bundle
bundle=$(realpath result)
state=$(mktemp -d)
mkdir "$state/catalog" "$state/report"
(cd "$state/catalog" && exec "$bundle/guests/catalog/runner/bin/microvm-run") </dev/null >"$state/catalog/console.log" 2>&1 &
curl --fail --retry 30 --retry-all-errors --retry-delay 1 --max-time 2 http://127.0.0.1:18080/items.json
(cd "$state/report" && "$bundle/guests/report/runner/bin/microvm-run")
```

The report prints the inventory on its console. To stop either guest, run its
`bin/microvm-shutdown` from the same writable directory used to start it.

On NixOS, import the bundle's `microvm.hostModule` into the host configuration.
The module gives the upstream MicroVM.nix host both guests and their link
configuration. The resulting host uses units named `microvm@catalog.service` and
`microvm@report.service` for this example. The report console is available via
`journalctl -u microvm@report.service`.
[Declarative MicroVMs](https://microvm-nix.github.io/microvm.nix/declarative.html)

## Guest behavior

The guest starts `billet.service` using the declared executable, literal
arguments and ordinary environment. Use a numeric `uid:gid` and a working
directory that exists in the guest. The renderer uses the declared limits to
size the VM, rounding up to vCPUs and MiB and adding 512 MiB for the guest OS. A
total of exactly 2048 MiB becomes 2049 MiB because QEMU hangs with exactly 2 GiB
of guest memory. Supported limits are up to 64 vCPUs and 1 TiB of application
memory. Systemd sets CPU and memory limits for the service and applies the
declared stop signal and grace period to its control group. A zero grace period
uses a one-microsecond timeout.

The stock guest has no virtual network interface. The capability report lists
which declarations require consumer setup, including networking, storage, secret
delivery, initialization, probes, restart, rollout, placement, and scaling.
Consumers can read the canonical manifest to obtain this policy and its
reference-only secret metadata. Preflight errors prevent rendering and warnings
allow it.

MicroVM.nix documents the native guest and runner options in its
[configuration reference](https://microvm-nix.github.io/microvm.nix/options.html).
