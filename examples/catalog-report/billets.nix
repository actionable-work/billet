{billetLib}: {
  pkgs,
  packages,
}: let
  inherit (pkgs) lib;
  catalogPackage = packages.catalog;
  billets = lib.mapAttrs (name: application:
    billetLib.mkBillet {
      inherit pkgs;
      modules = [
        {
          identity.name = name;
          resources = {
            cpuRequest = 100;
            cpuLimit = 1000;
            memoryRequest = 16777216;
            memoryLimit = 67108864;
          };
        }
        application
      ];
    }) {
    catalog = {
      identity.version = catalogPackage.version;
      oci.imageName = "billet-example/catalog";
      process = {
        package = catalogPackage;
        executable = "bin/catalog";
      };
      network.ports.http = {
        port = 8080;
        protocol = "http";
      };
    };
    report = {
      identity.version = "0.1.0";
      process = {
        package = pkgs.curl;
        executable = "bin/curl";
        argv = [
          "--fail"
          "--silent"
          "--show-error"
          "--retry"
          "10"
          "--retry-all-errors"
          "--retry-delay"
          "1"
          "--max-time"
          "3"
          "http://catalog:8080/items.json"
        ];
      };
    };
  };
in
  billets // {catalog-report = billetLib.mkBilletBundle {inherit pkgs billets;};}
