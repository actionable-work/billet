{
  pkgs,
  cli,
}: let
  diff = "${cli}/bin/billet diff";
  common = ''
    cat > before.json <<'JSON'
    {"schemaVersion":1,"normalizationVersion":1,"process":{"/mode~":"old-value-sentinel","argv":["run","arg"],"old":{"nested":true}}}
    JSON
  '';
  reject = ''
    reject() {
      expected="$1"
      shift
      status=0
      ${diff} "$@" > actual.json 2> diagnostic || status=$?
      test "$status" -eq 2
      test ! -s actual.json
      test "$(cat diagnostic)" = "billet: $expected"
    }
  '';
in
  {
    "billet:manifest-diff-semantics" =
      pkgs.runCommand "billet-manifest-diff-semantics" {
        nativeBuildInputs = [pkgs.jq];
        passthru.bloomery = [
          "BILLET-CLI-DIFF-001"
          "BILLET-CLI-DIFF-002"
          "BILLET-CLI-DIFF-003"
          "BILLET-CLI-DIFF-004"
          "BILLET-CLI-DIFF-005"
          "BILLET-CLI-DIFF-006"
          "BILLET-CLI-DIFF-007"
          "BILLET-CLI-DIFF-014"
        ];
      } ''
        ${common}
        cat > equivalent.json <<'JSON'
        {
          "process": {"old":{"nested":true},"argv":["run","arg"],"/mode~":"old-value-sentinel"},
          "normalizationVersion": 1, "schemaVersion": 1
        }
        JSON
        PATH=/no-binaries ${diff} before.json equivalent.json > equal.json
        jq -e '. == []' equal.json

        cat > after.json <<'JSON'
        {"schemaVersion":1,"normalizationVersion":1,"process":{"new":{"nested":"new-value-sentinel"},"argv":["arg","run"],"/mode~":"new-value-sentinel"}}
        JSON
        status=0
        ${diff} before.json after.json > actual.json || status=$?
        test "$status" -eq 1
        jq -e '. == [
          {"op":"replace","path":"/process/~1mode~0"},
          {"op":"replace","path":"/process/argv"},
          {"op":"add","path":"/process/new"},
          {"op":"remove","path":"/process/old"}
        ]' actual.json
        touch "$out"
      '';

    "billet:manifest-diff-errors" =
      pkgs.runCommand "billet-manifest-diff-errors" {
        passthru.bloomery = [
          "BILLET-CLI-DIFF-008"
          "BILLET-CLI-DIFF-009"
          "BILLET-CLI-DIFF-010"
          "BILLET-CLI-DIFF-011"
          "BILLET-CLI-DIFF-012"
          "BILLET-CLI-DIFF-013"
          "BILLET-CLI-DIFF-018"
        ];
      } ''
          ${common}
          ${reject}
          reject 'usage: billet diff BEFORE.json AFTER.json'
          reject 'usage: billet diff BEFORE.json AFTER.json' before.json
          reject 'usage: billet diff BEFORE.json AFTER.json' before.json before.json before.json
          reject 'cannot open before manifest' missing.json before.json
          reject 'cannot open after manifest' before.json missing.json
          printf '%s\n' 'invalid-json-value-sentinel' > malformed.json
          reject 'cannot read after manifest as JSON' before.json malformed.json
          printf '%s\n' '[]' > array.json
          reject 'before manifest must be a JSON object' array.json before.json
          printf '%s\n' '{"schemaVersion":2,"normalizationVersion":1}' > schema.json
          reject 'before manifest requires schemaVersion 1' schema.json before.json
          printf '%s\n' '{"schemaVersion":1,"normalizationVersion":1.0}' > normalization.json
          reject 'after manifest requires normalizationVersion 1' before.json normalization.json
          printf '%s\n' '{"normalizationVersion":1}' > schema-missing.json
          reject 'after manifest requires schemaVersion 1' before.json schema-missing.json
          printf '%s\n' '{"schemaVersion":1}' > normalization-missing.json
          reject 'before manifest requires normalizationVersion 1' normalization-missing.json before.json
        printf '%s\n' '{"schemaVersion":1,"normalizationVersion":1,"resources":{"memoryLimit":9.223372036854775807e18,"memory\u004cimit":1}}' > duplicate.json
        reject 'cannot read before manifest as JSON' duplicate.json before.json
        printf '%s\n' '{"schemaVersion":1,"normalizationVersion":1,"items":[{"key":true,"key":false}]}' > duplicate-array.json
        reject 'cannot read after manifest as JSON' before.json duplicate-array.json
          touch "$out"
      '';

    "billet:manifest-diff-numbers" =
      pkgs.runCommand "billet-manifest-diff-numbers" {
        nativeBuildInputs = [pkgs.jq];
        passthru.bloomery = ["BILLET-CLI-DIFF-015" "BILLET-CLI-DIFF-016"];
      } ''
        ${reject}
        numeric_manifest() {
          printf '{"schemaVersion":1,"normalizationVersion":1,"resources":{"memoryLimit":%s}}\n' "$2" > "$1"
        }
        numeric_manifest before.json 9223372036854775806
        numeric_manifest after.json 9223372036854775807
        status=0
        ${diff} before.json after.json > changed.json || status=$?
        test "$status" -eq 1
        jq -e '. == [{"op":"replace","path":"/resources/memoryLimit"}]' changed.json
        ${diff} after.json after.json > equal.json
        jq -e '. == []' equal.json

        numeric_manifest negative.json -9223372036854775808
        ${diff} negative.json negative.json > equal.json
        jq -e '. == []' equal.json

        numeric_manifest exponent-before.json 9.223372036854775806e18
        numeric_manifest exponent-after.json 9.223372036854775807e18
        reject 'before manifest numbers require canonical signed 64-bit integers' exponent-before.json exponent-after.json
        reject 'after manifest numbers require canonical signed 64-bit integers' before.json exponent-after.json
        for number in 9223372036854775808 -9223372036854775809 '[1.25]' -0; do
          numeric_manifest invalid.json "$number"
          reject 'after manifest numbers require canonical signed 64-bit integers' before.json invalid.json
        done
        touch "$out"
      '';
  }
  // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    "billet:manifest-diff-native-paths" =
      pkgs.runCommand "billet-manifest-diff-native-paths" {
        nativeBuildInputs = [pkgs.jq];
        passthru.bloomery = ["BILLET-CLI-DIFF-017"];
      } ''
        ${common}
        ${reject}
        native_before=$(printf 'before-\377.json')
        native_after=$(printf 'after-\376.json')
        cp before.json "$native_before"
        cp before.json "$native_after"
        ${diff} "$native_before" "$native_after" > equal.json
        jq -e '. == []' equal.json
        rm "$native_after"
        reject 'cannot open after manifest' "$native_before" "$native_after"
        touch "$out"
      '';
  }
