{
  pkgs,
  billetLib,
  catalogReport,
  catalogExecutable,
}: let
  fixture = billetLib.mkBillet {
    inherit pkgs;
    modules = [
      ../examples/hello/application.nix
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
  project = "${pkgs.docker-compose}/bin/docker-compose --project-name billet-catalog-report -f ${catalogReport}/compose.yaml";
  docker = "${pkgs.docker-client}/bin/docker";
  reference = fixture.ociImage.imageRefUnsafe;
in {
  "billet:compose-artifact" = pkgs.testers.runNixOSTest {
    name = "billet-compose-artifact";
    globalTimeout = 180;
    qemu.forceAccel = true;
    passthru.bloomery = ["BILLET-IR-TARGETS-006" "BILLET-IR-TARGETS-007" "BILLET-IR-TARGETS-008" "BILLET-IR-TARGETS-009" "BILLET-IR-TARGETS-010" "BILLET-IR-TARGETS-011" "BILLET-IR-TARGETS-012" "BILLET-IR-TARGETS-013" "BILLET-IR-TARGETS-014" "BILLET-IR-TARGETS-015" "BILLET-IR-TARGETS-016" "BILLET-IR-TARGETS-017" "BILLET-IR-TARGETS-024"];
    nodes.machine = {
      virtualisation = {
        memorySize = 2048;
        cores = 2;
        diskSize = 4096;
        docker.enable = true;
      };
    };
    testScript = ''
      import hashlib
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

      with subtest("independent Billets share the Compose network"):
          rendered = json.loads(machine.succeed("cat ${catalogReport}/compose.yaml"))
          parsed = json.loads(machine.succeed("${project} config --format json"))
          services = {"catalog", "report"}
          assert set(parsed["services"]) == services
          assert set(rendered["x-billet"]["services"]) == services
          for name in sorted(services):
              metadata = rendered["x-billet"]["services"][name]
              assert metadata["manifest"] == f"./manifests/{name}.json"
              manifest = machine.succeed(f"cat ${catalogReport}/manifests/{name}.json")
              assert json.loads(manifest)["identity"]["name"] == name
              digest = "sha256:" + hashlib.sha256(manifest.encode()).hexdigest()
              assert metadata["manifestDigest"] == digest
              image = parsed["services"][name]["image"]
              machine.succeed(f"${docker} image load --input ${catalogReport}/images/{name}.tar")
              inspection = json.loads(machine.succeed(f"${docker} image inspect {image}"))[0]
              assert inspection["Config"]["Labels"]["org.actionable-work.billet.manifest-digest"] == digest
              if name == "catalog":
                  assert inspection["Config"]["Entrypoint"] == ["${catalogExecutable}"]
          report = machine.succeed("${project} up --no-build --exit-code-from report 2>&1")
          expected = '{"items":[{"inStock":true,"sku":"notebook"}]}'
          assert expected in report, report
          machine.succeed("${project} down --volumes")
          assert machine.succeed("${docker} ps -aq").strip() == ""
    '';
  };
}
