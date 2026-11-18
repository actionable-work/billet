# Public build boundary

Billet builds from this repository plus public flake inputs pinned by flake.lock.
Use Bloomery's `mkFlake` API and required config.toml. Register `tests/flake.nix`
through `[flakes.tests]` in that configuration. Its checks are elevated individually
with a `tests:` prefix, preserving their requirement metadata; opt-in smoke apps
use the same prefix. Test definitions and fixture composition belong to that
subflake. The root flake exposes the library/examples and passes the parent inputs
through Bloomery's supported composition interface. Never import adjacent/private
source paths. The subflake follows the parent's pinned public dependencies.
Standalone `lib.mkBillet` selects the supplied pkgs system and validates `systems`.
The initial hosted x86_64-linux profile is a consumer restriction, not a restriction
on the portable schema. Only actually run systems have runtime acceptance evidence.
Licensing is MIT OR Apache-2.0.

Container construction uses the public flake-locked nix2container backend; its
nixpkgs follows the project's pin. Repository-owned tooling and acceptance
harnesses use Rust. The upstream NixOS test driver supplies its own Python runtime
to orchestrate the isolated Docker qualification VM; the acceptance logic remains
in the Rust harnesses. Repository CLI/runtime tooling does not require Python.
