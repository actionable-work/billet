# Public build boundary

Billet builds from this repository plus public flake inputs pinned by flake.lock.
Use Bloomery's `mkFlake` API and required config.toml; additive checks enter through
its documented extraOutputs callback. Never import adjacent/private source paths.
Standalone `lib.mkBillet` selects the supplied pkgs system and validates `systems`.
The initial hosted x86_64-linux profile is a consumer restriction, not a restriction
on the portable schema. Only actually run systems have runtime acceptance evidence.
Licensing is MIT OR Apache-2.0.

Container construction uses the public flake-locked nix2container backend; its
nixpkgs follows the project's pin. Repository-owned tooling and acceptance
harnesses use Rust. No Python runtime is required by repository commands.
