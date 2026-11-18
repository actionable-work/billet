{pkgs}: {
  # The test flake's formatter only covers this subflake; keep the public
  # library and the Bloomery-free hello example formatted as well.
  "billet:public-format" = pkgs.runCommand "billet-public-format" {} ''
    ${pkgs.alejandra}/bin/alejandra --check ${../flake.nix} ${../lib} ${../examples/hello}
    touch "$out"
  '';
}
