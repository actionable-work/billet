{
  pkgs,
  billetLib,
}: let
  fixture = billetLib.mkBillet {
    inherit pkgs;
    modules = [
      ../examples/hello.nix
      {
        rollout.minReadySeconds = 23;
        secrets.database = {
          external = "runtime/database";
          target = "/run/secrets/database";
        };
      }
    ];
  };
  bundle = fixture.dockerCompose.bundle;
  compose = "${pkgs.docker-compose}/bin/docker-compose --project-name billet-artifact -f ${bundle}/compose.yaml";
  docker = "${pkgs.docker-client}/bin/docker";
  reference = fixture.ociImage.imageRefUnsafe;
in {
  "billet:compose-artifact" = pkgs.testers.runNixOSTest {
    name = "billet-compose-artifact";
    globalTimeout = 180;
    qemu.forceAccel = true;
    passthru.bloomery = ["BILLET-IR-TARGETS-006" "BILLET-IR-TARGETS-007" "BILLET-IR-TARGETS-008" "BILLET-IR-TARGETS-009" "BILLET-IR-TARGETS-010" "BILLET-IR-TARGETS-011" "BILLET-IR-TARGETS-012" "BILLET-IR-TARGETS-013"];
    nodes.machine = {
      virtualisation = {
        memorySize = 2048;
        cores = 2;
        diskSize = 4096;
        docker.enable = true;
      };
    };
    testScript = ''
      import json

      machine.start()
      machine.wait_for_unit("docker.service")
      machine.succeed("cmp ${fixture.manifest} ${bundle}/manifest.json")
      manifest = json.loads(machine.succeed("cat ${bundle}/manifest.json"))
      assert manifest["rollout"]["minReadySeconds"] == 23
      assert manifest["secrets"]["database"] == {
          "external": "runtime/database", "mode": "file",
          "target": "/run/secrets/database", "required": True,
      }
      rendered = json.loads(machine.succeed("cat ${bundle}/compose.yaml"))
      assert rendered == {
          "services": {"hello": {"image": "${reference}", "pull_policy": "never"}},
          "x-billet": {"manifest": "./manifest.json", "manifestDigest": "${fixture.manifestDigest}"},
      }
      machine.succeed("${docker} image load --input ${bundle}/image.tar")
      image = json.loads(machine.succeed("${docker} image inspect ${reference}"))[0]
      assert image["Config"]["Labels"]["org.actionable-work.billet.manifest-digest"] == "${fixture.manifestDigest}"
      config = json.loads(machine.succeed("${compose} config --format json"))
      assert list(config["services"]) == [manifest["identity"]["name"]]
      assert config["services"]["hello"]["image"] == "${reference}"
      assert config["services"]["hello"]["pull_policy"] == "never"
      assert "Hello from Billet" in machine.succeed("${compose} up --no-build --exit-code-from hello 2>&1")
      machine.succeed("${compose} down --volumes")
      assert machine.succeed("${docker} ps -aq").strip() == ""
    '';
  };
}
