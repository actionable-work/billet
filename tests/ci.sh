#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

nix flake check .
nix flake check ./examples/hello
nix flake check ./examples/catalog-report
nix flake check ./examples/guestbook
nix flake check ./tests

(
  cd tests
  nix develop --command bloomery check --no-write
)
(
  cd examples/catalog-report
  nix develop --command bloomery check --no-write
)

# Exercise the integrated constructor before the public Bloomery lock is updated.
if [[ -n ${BILLET_BLOOMERY_FLAKE:-} ]]; then
  nix flake check ./examples/catalog-report --override-input bloomery "$BILLET_BLOOMERY_FLAKE"
  nix flake check ./tests --override-input bloomery "$BILLET_BLOOMERY_FLAKE"
fi
