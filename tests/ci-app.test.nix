{
  pkgs,
  app,
}: {
  "billet:ci-app" = assert app.type == "app";
    pkgs.runCommand "billet-ci-app" {
      passthru.bloomery = ["BILLET-PUBLIC-BUILD-008" "BILLET-PUBLIC-BUILD-009"];
    } ''
      checkout=$PWD/checkout
      mkdir -p "$checkout/lib" "$checkout/tests" "$checkout/examples/hello"
      touch "$checkout/flake.nix" "$checkout/lib/default.nix"
      printf '#!${pkgs.runtimeShell}\necho "ran $0 $*"\n' > "$checkout/tests/ci.sh"
      chmod +x "$checkout/tests/ci.sh"

      output=$(cd "$checkout/examples/hello" && ${app.program} --flag)
      test "$output" = "ran $checkout/tests/ci.sh --flag"

      mkdir outside
      if (cd outside && ${app.program}) 2> error; then
        echo "expected failure outside a checkout" >&2
        exit 1
      fi
      grep -q "inside a Billet checkout" error
      touch "$out"
    '';
}
