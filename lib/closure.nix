{
  pkgs,
  system,
  ir,
  canonicalJSON,
  manifestDigest,
  runtimeRoots,
  primaryCommands,
}:
pkgs.stdenvNoCC.mkDerivation {
  name = "billet-${ir.identity.name}-closure-v1";
  __structuredAttrs = true;
  exportReferencesGraph.runtime = runtimeRoots;
  nativeBuildInputs = [pkgs.jq pkgs.coreutils];
  manifestJSON = canonicalJSON;
  inherit manifestDigest system;
  roots = runtimeRoots;
  commands =
    map (p: {
      package = toString p.command.package;
      executable = "${p.command.package}/${p.command.executable}";
      diagnostic = p.field;
    })
    primaryCommands;
  buildCommand = ''
    out=''${outputs[out]}
    while IFS= read -r command; do
      package=$(printf '%s' "$command" | jq -r .package)
      executable=$(printf '%s' "$command" | jq -r .executable)
      field=$(printf '%s' "$command" | jq -r .diagnostic)
      resolved=$(realpath -e -- "$executable" 2>/dev/null) || {
        echo "billet: $field: executable does not exist" >&2; exit 1;
      }
      case "$resolved" in
        "$package"/*) ;;
        *) echo "billet: $field: executable escapes package output" >&2; exit 1 ;;
      esac
      if ! test -f "$resolved" || ! test -x "$resolved"; then
        echo "billet: $field: expected executable regular file" >&2; exit 1
      fi
    done < <(jq -c '.commands[]' "$NIX_ATTRS_JSON_FILE")
    mkdir -p "$out"
    jq -jr .manifestJSON "$NIX_ATTRS_JSON_FILE" > "$out/manifest.json"
    jq -cS '{schemaVersion: 1, system, manifestDigest, roots: (.roots | sort | unique),
      paths: (.runtime | map({path, narHash, narSize, references: (.references | sort | unique)}) | sort_by(.path))}' \
      "$NIX_ATTRS_JSON_FILE" > "$out/descriptor.json"
    jq -r '.paths[].path' "$out/descriptor.json" > "$out/store-paths"
  '';
}
