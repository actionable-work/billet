# Public build boundary

Billet's public root exports the Nix library and the repository formatter. It
pins nixpkgs, nix2container, MicroVM.nix, and treefmt-nix directly. Test and
example subflakes have their own entry points and locks.

## Qualification

`tests/flake.nix` owns artifact qualification, fixture composition, the artifact
CLI fixture, and the optional smoke app. It imports the public library as an
input and exports each test as an individual Nix check with its requirement
metadata. It uses Bloomery to build the Rust harness and check its
specifications. The CI script runs the root, test, and example flakes through
their public entry points.

### CI app

The test flake exports `apps.<system>.ci`; the public root does not export apps.
The app searches from the working directory up to the nearest Billet checkout
and runs that checkout's `tests/ci.sh`. It runs on the writable checkout rather
than a store copy because the examples' `path:` inputs and Bloomery runs read
the workspace. Outside a checkout it exits with an error.

## Public library

Standalone `lib.mkBillet` selects the supplied pkgs system and validates
`systems`. The initial hosted x86_64-linux profile is a consumer restriction,
not a restriction on the portable schema. Only actually run systems have runtime
acceptance evidence. Licensing is MIT OR Apache-2.0.

Container construction uses the public flake-locked nix2container backend; its
nixpkgs follows the project's pin. Repository-owned tooling and acceptance
harnesses use Rust. The upstream NixOS test driver runs the isolated Docker
qualification VM and its Compose consumer assertions through its Python test
interface. Public artifact operations use `nix eval` and `nix build`.

## Formatting

The public root exports `formatter.<system>` from treefmt-nix for every system
it lists. The formatter covers the whole repository, including the test and
example subflakes. It uses the same formatters and ordering as the Bloomery
workspaces, so the two never disagree on a file, and adds Prettier for Markdown.
`AGENTS.md` marks the tree root, so `nix fmt` from the repository root formats
the whole checkout.

The root also exports `checks.<system>.formatting`, which fails when any tracked
file differs from the formatter's output. The test flake re-exports that check
as `billet:public-format`.
