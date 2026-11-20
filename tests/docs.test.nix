# Executes the documented commands. See PUBLIC/design/documentation.md.
{
  pkgs,
  billet,
  bloomery,
  nixpkgs,
  doctest,
  hello,
  catalog,
  guestbook,
}: let
  inherit (pkgs) lib;
  docs = import ./docs.nix {inherit pkgs doctest;};
  inherit (docs) doc harness mkScenario system;
  bind = blocks: map (name: records.${name}) blocks;
  # Requirement records for each executed block, in document order.
  records = {
    readme-compose = "BILLET-PUBLIC-DOCS-007";
    getting-started-check = "BILLET-PUBLIC-DOCS-008";
    getting-started-canonical = "BILLET-PUBLIC-DOCS-009";
    getting-started-digest = "BILLET-PUBLIC-DOCS-010";
    getting-started-closure = "BILLET-PUBLIC-DOCS-011";
    bloomery-build = "BILLET-PUBLIC-DOCS-012";
    docker-load = "BILLET-PUBLIC-DOCS-013";
    docker-reference = "BILLET-PUBLIC-DOCS-014";
    docker-copy = "BILLET-PUBLIC-DOCS-015";
    docker-run = "BILLET-PUBLIC-DOCS-016";
    docker-run-options = "BILLET-PUBLIC-DOCS-017";
    docker-inspect = "BILLET-PUBLIC-DOCS-018";
    docker-layout = "BILLET-PUBLIC-DOCS-019";
    compose-report = "BILLET-PUBLIC-DOCS-020";
    compose-build = "BILLET-PUBLIC-DOCS-021";
    compose-up = "BILLET-PUBLIC-DOCS-022";
    compose-down = "BILLET-PUBLIC-DOCS-023";
    compose-bundle = "BILLET-PUBLIC-DOCS-024";
    kubernetes-build = "BILLET-PUBLIC-DOCS-025";
    kubernetes-apply = "BILLET-PUBLIC-DOCS-026";
    kubernetes-namespace-apply = "BILLET-PUBLIC-DOCS-027";
    kubernetes-bundle = "BILLET-PUBLIC-DOCS-028";
    microvm-build = "BILLET-PUBLIC-DOCS-029";
    microvm-bundle = "BILLET-PUBLIC-DOCS-030";
    guestbook-secrets = "BILLET-PUBLIC-DOCS-038";
    guestbook-up = "BILLET-PUBLIC-DOCS-039";
    guestbook-migrate = "BILLET-PUBLIC-DOCS-040";
    guestbook-request = "BILLET-PUBLIC-DOCS-041";
  };

  # Guide projects, bound to the checkout under test.
  gettingStarted = (docs.materialize {
    flake = "getting-started-flake";
    files."application.nix" = "getting-started-application";
  }).outputs {inherit billet nixpkgs;};
  readme = (docs.materialize {
    flake = "readme-flake";
    files."application.nix" = "readme-application";
  }).outputs {inherit billet nixpkgs;};
  bloomeryProject = (docs.materialize {
    flake = "bloomery-flake";
    files."billets.nix" = "bloomery-billets";
    replacements."root = ./.;" = "root = ${../examples/catalog-report};";
  }).outputs {inherit billet bloomery nixpkgs;};
  helloNamespace = lib.recursiveUpdate hello {
    billets.${system}.hello = billet.lib.mkBillet {
      pkgs = nixpkgs.legacyPackages.${system};
      modules = [../examples/hello/application.nix (docs.moduleBlock "kubernetes-namespace-module")];
    };
  };
  digest = builtins.unsafeDiscardStringContext gettingStarted.billets.${system}.hello.manifestDigest;
  inventory = ''"inStock":true'';
  ensureNamespace = harness "use an existing namespace" "kubectl get namespace my-namespace >/dev/null 2>&1 || kubectl create namespace my-namespace";

  sandbox = {
    getting-started = mkScenario {
      name = "getting-started";
      qualification.passthru.bloomery = ["BILLET-PUBLIC-DOCS-008" "BILLET-PUBLIC-DOCS-009" "BILLET-PUBLIC-DOCS-010" "BILLET-PUBLIC-DOCS-011"];
      flakes."." = gettingStarted;
      uses = ["getting-started-application" "getting-started-flake"];
      steps = [
        (doc "getting-started-check")
        (doc "getting-started-canonical")
        (doc "getting-started-digest")
        (doc "getting-started-closure")
        (harness "the descriptor was written" "test -s result-closure/descriptor.json")
      ];
    };
    bloomery = mkScenario {
      name = "bloomery";
      qualification.passthru.bloomery = ["BILLET-PUBLIC-DOCS-012"];
      flakes."." = bloomeryProject;
      uses = ["bloomery-flake" "bloomery-billets"];
      steps = [
        (doc "bloomery-build")
        (harness "the bundle has a Compose file" "test -s result/compose.yaml")
      ];
    };
    microvm-build = mkScenario {
      name = "microvm-build";
      qualification.passthru.bloomery = ["BILLET-PUBLIC-DOCS-029"];
      flakes."examples/hello" = hello;
      steps = [
        (doc "microvm-build")
        (harness "the bundle has a runner" "test -x result/runner/bin/microvm-run")
      ];
    };
    microvm-bundle = mkScenario {
      name = "microvm-bundle";
      qualification.passthru.bloomery = ["BILLET-PUBLIC-DOCS-030"];
      flakes."examples/catalog-report" = catalog;
      steps = [(doc "microvm-bundle")];
      until = inventory;
      timeout = 900;
    };
  };

  docker = [
    (mkScenario {
      name = "readme";
      flakes."." = readme;
      uses = ["readme-application" "readme-flake"];
      steps = [
        (doc "readme-compose")
        (harness "the service printed its greeting" "docker compose -f result/compose.yaml logs | grep -F 'Hello from Billet'")
        (harness "remove the project" "docker compose -f result/compose.yaml down")
      ];
    })
    (mkScenario {
      name = "docker";
      flakes."." = gettingStarted;
      steps = [
        (doc "docker-load")
        (doc "docker-reference")
        (doc "docker-copy")
        (doc "docker-run")
        (harness "provide the secret file" "printf 'example secret\\n' > database")
        (doc "docker-run-options")
        (doc "docker-inspect")
        (harness "the label is the manifest digest" ''
          test "$(docker image inspect "$image" --format '{{index .Config.Labels "org.actionable-work.billet.manifest-digest"}}')" = ${lib.escapeShellArg digest}
        '')
        (doc "docker-layout")
        (harness "the layout has an index" "test -s hello-oci/index.json")
      ];
    })
    (mkScenario {
      name = "compose";
      flakes."." = gettingStarted;
      steps = [
        (doc "compose-report")
        (doc "compose-build")
        (doc "compose-up")
        (harness "the service printed its greeting" "docker compose -f result/compose.yaml logs | grep -F 'Hello from Billet'")
        (doc "compose-down")
        (harness "the project was removed" ''test -z "$(docker ps --all --quiet)"'')
      ];
    })
    (mkScenario {
      name = "compose-bundle";
      cwd = "examples/catalog-report";
      flakes."examples/catalog-report" = catalog;
      steps = [(doc "compose-bundle")];
      until = inventory;
    })
    (mkScenario {
      name = "guestbook";
      flakes."examples/guestbook" = guestbook;
      steps = [
        (doc "guestbook-secrets")
        (doc "guestbook-up")
        (harness "the guestbook answers but is not ready before the migration" ''
          url="http://127.0.0.1:$(docker compose -f result/compose.yaml port guestbook 8080 | head -n 1 | cut -d: -f2)"
          for _ in $(seq 60); do curl -fsS "$url/healthz" >/dev/null && break; sleep 1; done
          test "$(curl -sS -o /dev/null -w '%{http_code}' "$url/readyz")" = 503
        '')
        (doc "guestbook-migrate")
        (doc "guestbook-request")
        (harness "the entry was stored" ''curl -fsS "http://127.0.0.1:$port/entries" | grep -F '"author": "ada"' '')
        (harness "remove the project and its volume" "docker compose -f result/compose.yaml down --volumes")
      ];
    })
  ];

  kubernetes = [
    (mkScenario {
      name = "kubernetes-namespace";
      cwd = "examples/hello";
      flakes."examples/hello" = helloNamespace;
      uses = ["kubernetes-namespace-module"];
      steps = [
        (harness "the namespace starts absent" "! kubectl get namespace my-namespace")
        (doc "kubernetes-namespace-apply")
        (harness "the List created the namespace and Deployment" "kubectl -n my-namespace get namespace/my-namespace deployment/hello")
      ];
    })
    (mkScenario {
      name = "kubernetes-hello";
      cwd = "examples/hello";
      flakes."examples/hello" = hello;
      steps = [
        (doc "kubernetes-build")
        ensureNamespace
        (doc "kubernetes-apply")
        (harness "the Deployment exists" "kubectl -n my-namespace get deployment/hello")
      ];
    })
    (mkScenario {
      name = "kubernetes-bundle";
      flakes."examples/catalog-report" = catalog;
      steps = [
        ensureNamespace
        (doc "kubernetes-bundle")
        (harness "the report logged the inventory" ''kubectl -n my-namespace logs "job/$report_job" | grep -F '${inventory}' '')
      ];
    })
  ];

  dockerQualification.passthru.bloomery = ["BILLET-PUBLIC-DOCS-007" "BILLET-PUBLIC-DOCS-013" "BILLET-PUBLIC-DOCS-014" "BILLET-PUBLIC-DOCS-015" "BILLET-PUBLIC-DOCS-016" "BILLET-PUBLIC-DOCS-017" "BILLET-PUBLIC-DOCS-018" "BILLET-PUBLIC-DOCS-019" "BILLET-PUBLIC-DOCS-020" "BILLET-PUBLIC-DOCS-021" "BILLET-PUBLIC-DOCS-022" "BILLET-PUBLIC-DOCS-023" "BILLET-PUBLIC-DOCS-024" "BILLET-PUBLIC-DOCS-038" "BILLET-PUBLIC-DOCS-039" "BILLET-PUBLIC-DOCS-040" "BILLET-PUBLIC-DOCS-041"];
  kubernetesQualification.passthru.bloomery = ["BILLET-PUBLIC-DOCS-025" "BILLET-PUBLIC-DOCS-026" "BILLET-PUBLIC-DOCS-027" "BILLET-PUBLIC-DOCS-028"];
  # Each check's literal records must match the blocks it executes.
  traced = qualification: blocks: let
    sorted = lib.sort builtins.lessThan;
  in
    assert lib.assertMsg (sorted qualification.passthru.bloomery == sorted (bind blocks)) "doctest records differ from executed blocks: ${toString blocks}"; qualification;

  scenarios = builtins.attrValues sandbox ++ docker ++ kubernetes;
  blocksOf = list: lib.concatMap docs.blocks list;
  vmScript = list:
    lib.concatMapStringsSep "\n" (scenario: ''
      machine.succeed("mkdir -p /tmp/doctest/${scenario.name} && cd /tmp/doctest/${scenario.name} && BILLET_DOCTEST_ROOT=/tmp/doctest/${scenario.name} ${lib.escape ["\"" "\\"] (docs.command scenario)} >&2", timeout=${toString (scenario.timeout + 60)})
    '')
    list;

  # Synthetic documents for the coverage rules.
  synthetic = text: docs.coverage [(docs.parse "test.md" text)] [];
  fenced = annotation: lang: "${annotation}\n\n```${lang}\ntrue\n```\n";
  rejects = pattern: errors: builtins.any (error: builtins.match ".*${pattern}.*" error != null) errors;
  coverage = docs.coverage docs.documents (docs.used scenarios);
in
  lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == system) {
    "billet:doc-coverage" = assert lib.assertMsg (coverage == []) ("documentation coverage:\n" + lib.concatStringsSep "\n" coverage);
    assert rejects "shell block has no doctest annotation" (synthetic "```sh\ntrue\n```\n");
    assert synthetic "```text\nfree\n```\n" == [];
    assert rejects "skip annotation has no reason" (synthetic (fenced "<!-- doctest: skip -->" "sh"));
    assert synthetic (fenced "<!-- doctest: skip external service -->" "sh") == [];
    assert rejects "annotation is not followed by a fence" (synthetic "<!-- doctest: stray -->\n\nprose\n");
    assert rejects "duplicate block name" (docs.coverage [(docs.parse "test.md" (fenced "<!-- doctest: twice -->" "sh" + fenced "<!-- doctest: twice -->" "sh"))] ["twice"]);
    assert rejects "no scenario uses" (synthetic (fenced "<!-- doctest: unused -->" "sh"));
    assert rejects "several scenarios use" (docs.coverage [(docs.parse "test.md" (fenced "<!-- doctest: shared -->" "sh"))] ["shared" "shared"]);
    assert rejects "missing block absent" (docs.coverage [] ["absent"]);
      pkgs.runCommand "billet-doc-coverage" {
        passthru.bloomery = ["BILLET-PUBLIC-DOCS-001" "BILLET-PUBLIC-DOCS-002" "BILLET-PUBLIC-DOCS-003" "BILLET-PUBLIC-DOCS-004" "BILLET-PUBLIC-DOCS-005" "BILLET-PUBLIC-DOCS-006" "BILLET-PUBLIC-DOCS-033"];
      } ''touch "$out"'';

    "billet:doc-stand-in" = let
      table = pkgs.writeText "stand-in-table.json" (builtins.toJSON {
        refs = {
          "examples/hello#billets.out" = {
            path = "${pkgs.hello}";
            program = "${pkgs.hello}/bin/hello";
          };
          "examples/hello#billets.name".value = "hello";
        };
        checks."examples/hello" = ["${pkgs.hello}"];
      });
    in
      pkgs.runCommand "billet-doc-stand-in" {
        nativeBuildInputs = [doctest];
        passthru.bloomery = ["BILLET-PUBLIC-DOCS-031" "BILLET-PUBLIC-DOCS-032"];
      } ''
        mkdir -p root/examples/hello bin
        ln -s ${doctest}/bin/billet-doctest bin/nix
        export PATH=$PWD/bin:$PATH BILLET_DOCTEST_ROOT=$PWD/root BILLET_DOCTEST_TABLE=${table}
        cd root
        nix build ./examples/hello#billets.out -o hello-link
        test "$(readlink hello-link)" = ${pkgs.hello}
        (cd examples/hello && test "$(nix eval --raw .#billets.name)" = hello && nix flake check)
        test "$(nix eval --json ./examples/hello#billets.name)" = '"hello"'
        nix run ./examples/hello#billets.out -- --greeting=stand-in | grep -Fx stand-in
        for invocation in "develop --command true" "build --impure ./examples/hello#billets.out" "eval --raw .#billets.name" "build github:o/r#x"; do
          if output=$(nix $invocation 2>&1); then
            echo "accepted: nix $invocation"
            exit 1
          fi
          echo "$output" | grep -E 'unsupported|unresolved|no flake|outside' >/dev/null
        done
        touch "$out"
      '';
  }
  // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == system) (lib.mapAttrs' (name: scenario:
    lib.nameValuePair "billet:doc-${name}" (pkgs.runCommand "billet-doc-${name}" {
        nativeBuildInputs = [pkgs.coreutils pkgs.curl pkgs.jq];
        inherit (traced scenario.qualification (docs.blocks scenario)) passthru;
      } ''
        export HOME=$PWD/home BILLET_DOCTEST_ROOT=$PWD/root
        mkdir -p "$HOME" "$BILLET_DOCTEST_ROOT"
        ${docs.command scenario}
        touch "$out"
      ''))
  sandbox)
  // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == system) {
    "billet:doc-docker" = pkgs.testers.runNixOSTest {
      name = "billet-doc-docker";
      inherit (traced dockerQualification (blocksOf docker)) passthru;
      nodes.machine = {
        virtualisation = {
          memorySize = 3072;
          diskSize = 8192;
          docker.enable = true;
        };
        environment.systemPackages = [pkgs.jq pkgs.curl];
      };
      testScript = ''
        machine.wait_for_unit("docker.service")
        ${vmScript docker}
      '';
    };

    "billet:doc-kubernetes" = pkgs.testers.runNixOSTest {
      name = "billet-doc-kubernetes";
      inherit (traced kubernetesQualification (blocksOf kubernetes)) passthru;
      nodes.machine = {config, ...}: {
        virtualisation = {
          memorySize = 4096;
          cores = 2;
          diskSize = 8192;
        };
        networking.firewall.enable = false;
        services.k3s = {
          enable = true;
          disable = ["traefik" "servicelb" "local-storage" "metrics-server"];
          images = [config.services.k3s.package.airgap-images];
        };
        environment.systemPackages = [config.services.k3s.package pkgs.jq];
      };
      testScript = ''
        machine.wait_for_unit("k3s.service")
        machine.wait_until_succeeds("k3s kubectl get --raw=/readyz")
        machine.wait_until_succeeds("k3s kubectl wait --for=condition=Ready node --all --timeout=10s", timeout=180)
        machine.wait_until_succeeds("k3s kubectl -n kube-system get deployment/coredns", timeout=120)
        machine.succeed("k3s kubectl -n kube-system rollout status deployment/coredns --timeout=120s")
        ${vmScript kubernetes}
      '';
    };
  }
