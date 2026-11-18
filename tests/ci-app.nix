{pkgs}:
# CI needs a writable checkout: example flakes use `path:../..` inputs and
# Bloomery records runs in the workspace, so run the enclosing checkout's
# script rather than a store copy.
pkgs.writeShellApplication {
  name = "billet-ci";
  text = ''
    dir=$PWD
    while [ "$dir" != / ]; do
      if [ -f "$dir/flake.nix" ] && [ -f "$dir/lib/default.nix" ] && [ -x "$dir/tests/ci.sh" ]; then
        exec "$dir/tests/ci.sh" "$@"
      fi
      dir=$(dirname -- "$dir")
    done
    echo "billet-ci: run from inside a Billet checkout" >&2
    exit 2
  '';
}
