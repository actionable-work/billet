{
  pkgs,
  treefmt-nix,
  formatting,
}: let
  treefmt = (treefmt-nix.lib.evalModule pkgs ../treefmt.nix).config;
  # A minimal tree with the root marker and one misformatted Nix file.
  unformatted = pkgs.runCommand "billet-unformatted-fixture" {} ''
    mkdir -p "$out"
    touch "$out/AGENTS.md"
    printf '{a=1;}\n' > "$out/default.nix"
  '';
in {
  # The root formatting check covers every tracked file, including the test
  # and example subflakes.
  "billet:public-format" = pkgs.runCommand "billet-public-format" {
    inherit formatting;
    passthru.bloomery = ["BILLET-PUBLIC-BUILD-012"];
  } ''touch "$out"'';
  "billet:public-format-rejects" =
    pkgs.runCommand "billet-public-format-rejects" {
      failure = pkgs.testers.testBuildFailure (treefmt.build.check unformatted);
      passthru.bloomery = ["BILLET-PUBLIC-BUILD-011"];
    } ''
      grep -q 'default.nix' "$failure/testBuildFailure.log"
      touch "$out"
    '';
}
