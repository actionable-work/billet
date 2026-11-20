{
  pkgs,
  billetLib,
}: let
  inherit (pkgs) lib;
  fixtures = import ./fixtures.nix {inherit pkgs billetLib;};
  argv = ["" "two words" ";" "$(false)" "$MARKER" "\${MARKER}" "%n" "a\"b\\c\nd"];
  marker = "\"$PATH\" %n \\ quoted\nnext line";
  core = "${pkgs.coreutils}/bin";
  app = pkgs.writeShellScriptBin "microvm-app" ''
    set -eu
    trap 'printf "BILLET_GUEST_FAILED at line %s\n" "$LINENO"' ERR
    for expected in ${lib.escapeShellArgs argv}; do
      test "$1" = "$expected"
      shift
    done
    test "$#" = 0
    test "$MARKER" = ${lib.escapeShellArg marker}
    test "$PWD" = /tmp
    test "$(${core}/id -u):$(${core}/id -g)" = 12001:12002
    test "$(${core}/cat "$(${core}/cat "$DATA")")" = 'transitive runtime data'
    test "$(${core}/cat /sys/fs/cgroup/system.slice/billet.service/cpu.max)" = '250000 1000000'
    test "$(${core}/cat /sys/fs/cgroup/system.slice/billet.service/memory.max)" = '67108864'
    test "$(${core}/ls /sys/class/net)" = lo
    digest=$(${core}/sha256sum /etc/billet/manifest.json)
    trap 'echo BILLET_GUEST_STOPPED; exit 0' HUP
    echo "BILLET_GUEST_READY ''${digest%% *}"
    while true; do ${core}/sleep 1; done
  '';
  fixture = fixtures.evaluate (lib.recursiveUpdate fixtures.base {
    microvm.acceleration = "tcg";
    process = {
      package = app;
      executable = "bin/microvm-app";
      inherit argv;
      environment = {
        MARKER = marker;
        DATA = "${fixtures.middle}";
      };
      workingDirectory = "/tmp";
      user = "12001:12002";
    };
    resources.cpuLimit = 250;
    shutdown = {
      stopSignal = "SIGHUP";
      stopGracePeriodSeconds = 7;
    };
  });
  # The full acceptance fixture with a guest assertion script as its process.
  # Its secrets, storage, port, initialization and probe have no native
  # microVM mapping; the script checks that the guest provides none of them
  # while the probe and initialization executables remain in the guest store.
  initMarker = "/tmp/billet-initialized";
  fullInit = pkgs.writeShellScriptBin "initialize" ''${core}/touch ${initMarker}'';
  fullProbe = pkgs.writeShellScriptBin "probe" "echo BILLET_PROBE_RAN";
  fullApp = pkgs.writeShellScriptBin "microvm-full-app" ''
    set -eu
    trap 'printf "BILLET_GUEST_FAILED at line %s\n" "$LINENO"' ERR
    manifest=/etc/billet/manifest.json
    probe=$(${pkgs.jq}/bin/jq -r .probes.readiness.command.executable "$manifest")
    init=$(${pkgs.jq}/bin/jq -r '.initialization.steps[0].executable' "$manifest")
    test -f "$probe" && test -x "$probe"
    test "$("$probe")" = BILLET_PROBE_RAN
    test -f "$init" && test -x "$init"
    test ! -e ${initMarker}
    test ! -e /run/secrets/database
    test -z "''${APP_TOKEN+set}"
    test "$(${core}/cut -d ' ' -f 2 /proc/mounts | ${pkgs.gnugrep}/bin/grep -cxF /tmp/work || true)" = 0
    test "$(${core}/ls /sys/class/net)" = lo
    digest=$(${core}/sha256sum "$manifest")
    trap 'echo BILLET_GUEST_STOPPED; exit 0' TERM
    echo "BILLET_GUEST_READY ''${digest%% *}"
    while true; do ${core}/sleep 1; done
  '';
  full = fixtures.evaluate (lib.recursiveUpdate fixtures.full {
    microvm.acceleration = "tcg";
    process = {
      package = fullApp;
      executable = "bin/microvm-full-app";
      argv = [];
    };
    initialization.steps = [(builtins.head fixtures.full.initialization.steps // {package = fullInit;})];
    probes.readiness.command.package = fullProbe;
  });
  fullReport = full.microvm.capabilityReport;
  warned = field: builtins.any (d: d.severity == "warning" && d.field == field) fullReport.diagnostics;
  fullRendering =
    fullReport.canRender
    && builtins.all warned ["secrets.database" "secrets.token" "storage.scratch" "network.ports" "initialization.steps" "probes.readiness"];

  # Boot a packaged guest until its service reports the canonical digest, then
  # shut it down and require the service to report the stop signal.
  boot = name: billet: qualification: let
    inherit (billet.microvm) bundle file runner;
    digest = lib.removePrefix "sha256:" (builtins.unsafeDiscardStringContext billet.manifestDigest);
  in
    pkgs.runCommand name qualification ''
      cmp ${file} ${bundle}/microvm.json
      cmp ${billet.manifest} ${bundle}/manifest.json
      test "$(readlink ${bundle}/runner)" = ${runner}
      test "$(sha256sum ${bundle}/manifest.json | cut -d ' ' -f 1)" = ${digest}
      # The packaged QEMU command attaches no network device or host forwarding.
      grep -q qemu-system "$(readlink -f ${bundle}/runner/bin/microvm-run)"
      if grep -Eq -- '-netdev|-nic |hostfwd|virtio-net' "$(readlink -f ${bundle}/runner/bin/microvm-run)"; then
        echo 'runner declares a guest network device'; exit 1
      fi

      timeout -k 5s 180s ${bundle}/runner/bin/microvm-run </dev/null > console.log 2>&1 &
      pid=$!
      cleanup() {
        kill "$pid" 2>/dev/null || true
        tr -d '\r' <console.log
      }
      trap cleanup EXIT

      until grep -Eq '(^|: )BILLET_GUEST_READY ${digest}[[:space:]]*$' console.log &&
        grep -Fq 'Multi-User System' console.log; do
        kill -0 "$pid"
        if grep -Eq "BILLET_GUEST_FAILED|systemctl status billet.service" console.log; then exit 1; fi
        sleep 1
      done

      echo 'Guest reached multi-user.target and reported the canonical manifest digest'
      # Device discovery can finish after multi-user.target. Send a second
      # power event if the first arrived before logind was watching the button.
      timeout 20s ${bundle}/runner/bin/microvm-shutdown || timeout 45s ${bundle}/runner/bin/microvm-shutdown
      wait "$pid"
      grep -Eq '(^|: )BILLET_GUEST_STOPPED[[:space:]]*$' console.log
      mkdir -p "$out"
      cp console.log "$out/console.log"
      trap - EXIT
    '';
in {
  "billet:microvm-boot" = boot "billet-microvm-boot" fixture {
    passthru.bloomery = [
      "BILLET-IR-MICROVM-041"
      "BILLET-IR-MICROVM-042"
      "BILLET-IR-MICROVM-043"
      "BILLET-IR-MICROVM-044"
      "BILLET-IR-MICROVM-045"
      "BILLET-IR-MICROVM-046"
      "BILLET-IR-MICROVM-047"
      "BILLET-IR-MICROVM-048"
      "BILLET-IR-MICROVM-049"
      "BILLET-IR-MICROVM-050"
      "BILLET-IR-MICROVM-051"
      "BILLET-IR-MICROVM-052"
      "BILLET-IR-MICROVM-053"
      "BILLET-IR-MICROVM-054"
    ];
  };
  "billet:microvm-full-boot" = assert fullRendering;
    boot "billet-microvm-full-boot" full {
      passthru.bloomery = [
        "BILLET-IR-MICROVM-080"
        "BILLET-IR-MICROVM-081"
        "BILLET-IR-MICROVM-082"
        "BILLET-IR-MICROVM-083"
        "BILLET-IR-MICROVM-084"
        "BILLET-IR-MICROVM-085"
        "BILLET-IR-MICROVM-086"
        "BILLET-IR-MICROVM-087"
      ];
    };
}
