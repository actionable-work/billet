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
  inherit (fixture.microvm) bundle file runner;
  digest = lib.removePrefix "sha256:" (builtins.unsafeDiscardStringContext fixture.manifestDigest);
in {
  "billet:microvm-boot" =
    pkgs.runCommand "billet-microvm-boot" {
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
    } ''
      cmp ${file} ${bundle}/microvm.json
      cmp ${fixture.manifest} ${bundle}/manifest.json
      test "$(readlink ${bundle}/runner)" = ${runner}
      test "$(sha256sum ${bundle}/manifest.json | cut -d ' ' -f 1)" = ${digest}

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
}
