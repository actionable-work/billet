# The guestbook service: one Python script with psycopg from nixpkgs.
{writers}:
writers.writePython3Bin "guestbook" {
  libraries = ps: [ps.psycopg];
  flakeIgnore = ["E501"];
} (builtins.readFile ./guestbook.py)
