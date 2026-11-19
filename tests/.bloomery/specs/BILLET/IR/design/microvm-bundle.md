# Nix microVM application bundles

## Bundle outputs

`mkBilletBundle` exposes `microvm.capabilityReport`, `configuration`, `file`,
`bundle`, and `hostModule`. The report includes per-member preflight, scoped
diagnostics, and the union of required capabilities. Reject invalid bundle
structure or an ineligible member before evaluating its guest. Each member name
must be a lowercase DNS label starting with a letter for the guest hostname and
service alias. Reserve `localhost` for loopback.

`configuration` records link mappings, per-member NixOS settings, relative
runner and manifest paths, and manifest digests. The standalone `microvm.json`
can be built independently of the guests. The bundle includes that exact file,
the upstream runner for each guest under `guests/<name>/runner`, and the exact
canonical IR under `manifests/<name>.json`. `hostModule` contributes the same
evaluated guests to the upstream MicroVM.nix NixOS host module.

## Local guest links

Collect declared private connections across members. For a link between distinct
members, validate the named destination port and its protocol. Reuse one host
loopback listener per destination port. Assign host ports from
`microvm.hostPortBase`, default 18080, in sorted destination and port-name
order. Reject a range that exceeds the unprivileged TCP port space.

Give each participating guest a QEMU user network. Give each destination a
distinct address within the source guest's user network and publish its Billet
name in the source guest's host table. Use upstream QEMU forwarding to bridge
the declared destination port through the corresponding host loopback listener.
Order each networked application service after its guest network is online.
External links retain their declarations with an advisory. Members without a
mapped link boot with loopback only. Reject restrictive egress declarations on
members that need QEMU user networking. These routes supply connectivity. Host
access and network policy enforcement remain consumer responsibilities.

## Catalog and report

The example uses TCG and loopback port 18080. The catalog guest exposes its
private HTTP port to the report through the configured routes. The report prints
the inventory to its guest console. For a standalone launch, each runner uses
its own writable directory. A NixOS host can import the native module and use
the upstream units for the two guests.

## Qualification

`tests/microvm-bundle.test.nix` checks the preflight report and link capability
(059–061), rejection of mismatched protocol, port base, restricted egress and
hostnames (062–065), external advisories and isolated interfaces (066–067),
guest hostnames, native forwarding, destination resolution and network ordering
(068–071), and the upstream host target's units (072). The standalone file test
uses an unrealizable application program (073). The Linux check compares the
packaged settings, manifests and runner references (074–076), then boots both
bundled guests and reads the inventory at the host listener and the report
console (077–078).
