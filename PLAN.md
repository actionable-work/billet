# Per-replica network bandwidth reservations and limits

Implement the artifact contract in the
[bandwidth design](tests/.bloomery/specs/BILLET/IR/design/network-bandwidth.md).

1. Add the four optional rates, canonical normalization, per-direction
   validation, and separate reservation and limit capabilities. Verify existing
   v1 golden bytes and digests, each optional bound, and the combined manifest
   that Lineshaft consumes.
2. Add Kubernetes preflight that rejects requested minimums and supports maxima
   through the explicit Pod annotation profile for Deployments and Jobs. For
   Docker images, Compose, and Nix microVM, preserve all rates in the manifest.
   Add field-specific consumer-managed diagnostics to Compose and Nix microVM
   standalone and bundle reports.
3. Qualify the Kubernetes maximum profile in an isolated Linux cluster wired
   through `tests/flake.nix`. Verify each supported path and direction with
   concurrent flows and an uncapped baseline. Add granular Bloomery records with
   BI lineage and one executable witness per behavior.
4. Document the module, the distinction between reservation and maximum
   capabilities, and each target's prerequisites. Run Bloomery checks,
   `nix fmt`, and `./tests/ci.sh`.

The first Lineshaft consumer milestone is to reserve capacity at admission and
prove a managed private egress minimum under contention using the canonical
manifest. Qualify ingress and other paths separately. The runtime owns network
placement, scheduling and enforcement. Its implementation belongs in the
consuming runtime repository.
