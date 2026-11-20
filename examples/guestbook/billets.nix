# One bundle per environment: the guestbook, refined by that environment's
# overlay, and the shared PostgreSQL Billet.
{
  billetLib,
  pkgs,
}: let
  make = modules: billetLib.mkBillet {inherit pkgs modules;};
  postgres = make [./modules/postgres.nix];
  environment = overlay:
    billetLib.mkBilletBundle {
      inherit pkgs;
      billets = {
        guestbook = make [./modules/guestbook.nix overlay];
        inherit postgres;
      };
    };
in {
  dev = environment ./modules/dev.nix;
  prod = environment ./modules/prod.nix;
}
