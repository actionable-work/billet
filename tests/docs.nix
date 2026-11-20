# Documentation command qualification: Markdown parsing, coverage rules, and
# scenario construction. See PUBLIC/design/documentation.md.
{
  pkgs,
  doctest,
}: let
  inherit (pkgs) lib;
  system = "x86_64-linux";
  fence = line: builtins.match "```([A-Za-z0-9_+-]*).*" line;
  closing = line: builtins.match "```[[:space:]]*" line != null;
  annotation = line: builtins.match "<!-- doctest: (.*) -->[[:space:]]*" line;
  blank = line: builtins.match "[[:space:]]*" line != null;

  # Parse one Markdown document into fenced blocks and annotation errors.
  parse = file: text: let
    lines = lib.imap1 (number: line: {inherit number line;}) (lib.splitString "\n" text);
    misplaced = pending: "${file}:${toString pending.number}: annotation is not followed by a fence";
    step = state: {
      number,
      line,
    }:
      if state.open != null
      then
        if closing line
        then
          state
          // {
            open = null;
            blocks = state.blocks ++ [(state.open // {text = lib.concatStringsSep "\n" state.open.body;})];
          }
        else state // {open = state.open // {body = state.open.body ++ [line];};}
      else if fence line != null
      then
        state
        // {
          pending = null;
          open = {
            inherit file;
            line = number;
            lang = builtins.head (fence line);
            annotation = state.pending;
            body = [];
          };
        }
      else if annotation line != null
      then
        state
        // {
          pending = {
            inherit number;
            value = builtins.head (annotation line);
          };
          errors = state.errors ++ lib.optional (state.pending != null) (misplaced state.pending);
        }
      else if blank line
      then state
      else
        state
        // {
          pending = null;
          errors = state.errors ++ lib.optional (state.pending != null) (misplaced state.pending);
        };
    final =
      builtins.foldl' step {
        open = null;
        pending = null;
        blocks = [];
        errors = [];
      }
      lines;
  in {
    blocks = map (block: builtins.removeAttrs block ["body"]) final.blocks;
    errors =
      final.errors
      ++ lib.optional (final.pending != null) (misplaced final.pending)
      ++ lib.optional (final.open != null) "${file}:${toString final.open.line}: unterminated fence";
  };

  # Classify an annotation value as a skip with its reason or a block name.
  classify = block:
    if block.annotation == null
    then block // {name = null;}
    else let
      value = block.annotation.value;
      skip = builtins.match "skip( (.*))?" value;
    in
      block
      // (
        if skip != null
        then {
          name = null;
          skip = true;
          reason = lib.trim (toString (builtins.elemAt skip 1));
        }
        else {
          name = value;
          skip = false;
        }
      );

  # Coverage errors for parsed documents and the names that scenarios use.
  coverage = documents: used: let
    blocks = map classify (lib.concatMap (document: document.blocks) documents);
    at = block: "${block.file}:${toString block.line}";
    names = lib.filter (name: name != null) (map (block: block.name) blocks);
    count = name: list: builtins.length (builtins.filter (item: item == name) list);
  in
    lib.concatMap (document: document.errors) documents
    ++ lib.concatMap (block:
      lib.optional (block.lang == "sh" && block.annotation == null) "${at block}: shell block has no doctest annotation"
      ++ lib.optional (block.skip or false && block.reason == "") "${at block}: skip annotation has no reason"
      ++ lib.optional (block.name != null && builtins.match "[a-z0-9]+(-[a-z0-9]+)*" block.name == null) "${at block}: invalid block name ${block.name}"
      ++ lib.optional (block.name != null && count block.name names > 1) "${at block}: duplicate block name ${block.name}"
      ++ lib.optional (block.name != null && count block.name used == 0) "${at block}: no scenario uses ${block.name}"
      ++ lib.optional (block.name != null && count block.name used > 1) "${at block}: several scenarios use ${block.name}")
    blocks
    ++ map (name: "a scenario uses missing block ${name}") (lib.unique (lib.filter (name: !(builtins.elem name names)) used));

  markdown = dir:
    lib.concatLists (lib.mapAttrsToList (name: type:
      if type == "directory"
      then markdown (dir + "/${name}")
      else lib.optional (lib.hasSuffix ".md" name) (dir + "/${name}"))
    (builtins.readDir dir));
  sources = [../README.md] ++ markdown ../docs;
  relative = path: lib.removePrefix "${toString ../.}/" (toString path);
  documents = map (path: parse (relative path) (builtins.readFile path)) sources;
  named = lib.listToAttrs (map (block: lib.nameValuePair block.name block) (lib.filter (block: block.name != null) (map classify (lib.concatMap (document: document.blocks) documents))));
  block = name: named.${name} or (throw "doctest: missing documentation block ${name}");

  # A Nix module or flake written by a guide, with relative imports bound to
  # the other named blocks.
  materialize = {
    flake,
    files ? {},
    replacements ? {},
  }: let
    stored = lib.mapAttrs (name: id: builtins.toFile name (block id).text) files;
    bindings = lib.mapAttrs' (name: path: lib.nameValuePair "./${name}" "${path}") stored // replacements;
    text = lib.replaceStrings (builtins.attrNames bindings) (builtins.attrValues bindings) (block flake).text;
  in
    import (builtins.toFile "flake.nix" text);
  moduleBlock = id: import (builtins.toFile "${id}.nix" "{ ${(block id).text} }");

  normalize = path: let
    step = parts: part:
      if part == "" || part == "."
      then parts
      else if part == ".."
      then lib.init parts
      else parts ++ [part];
    parts = builtins.foldl' step [] (lib.splitString "/" path);
  in
    if parts == []
    then "."
    else lib.concatStringsSep "/" parts;

  # Resolve every flake reference in the scenario blocks to a table entry.
  table = scenario: let
    texts = map (step: step.text) (builtins.filter (step: step ? doc) scenario.steps);
    tokens = lib.unique (lib.concatMap (text: lib.filter builtins.isList (builtins.split "([^[:space:]\"'()=]*#[A-Za-z0-9._+-]+)" text)) texts);
    resolve = token: let
      reference = builtins.head token;
      parts = lib.splitString "#" reference;
      flake = normalize "${scenario.cwd}/${builtins.head parts}";
      attribute = builtins.elemAt parts 1;
      outputs = scenario.flakes.${flake} or (throw "doctest ${scenario.name}: no flake for ${flake} in ${reference}");
      value = lib.attrByPath (lib.splitString "." attribute) (throw "doctest ${scenario.name}: ${reference} does not exist") outputs;
    in
      lib.nameValuePair "${flake}#${attribute}" (
        if lib.isDerivation value
        then {
          path = value.outPath;
          program = "${value}/bin/${value.meta.mainProgram or (lib.getName value)}";
        }
        else {inherit value;}
      );
    cwd = normalize scenario.cwd;
    checks = lib.optionalAttrs (builtins.any (lib.hasInfix "nix flake check") texts) {
      ${cwd} = map (check: check.outPath) (builtins.attrValues scenario.flakes.${cwd}.checks.${system});
    };
  in
    pkgs.writeText "billet-doctest-${scenario.name}-table.json" (builtins.toJSON {
      refs = builtins.listToAttrs (map resolve tokens);
      inherit checks;
    });

  standIn = pkgs.runCommand "billet-doctest-nix" {} ''
    mkdir -p "$out/bin"
    ln -s ${doctest}/bin/billet-doctest "$out/bin/nix"
  '';

  # One Bash session per scenario. Harness steps state preconditions from the
  # guide's prose or check results after the documented commands.
  script = scenario: let
    directories = lib.unique ([scenario.cwd] ++ builtins.attrNames scenario.flakes);
    render = step:
      if step ? doc
      then ''
        echo '==> doctest ${step.doc} (${step.file}:${toString step.line})'
        ${step.text}
      ''
      else ''
        echo '==> harness: ${step.title}'
        ${step.harness}
      '';
  in
    pkgs.writeText "billet-doctest-${scenario.name}.sh" ''
      set -euo pipefail
      exec 2>&1
      root=''${BILLET_DOCTEST_ROOT:?}
      export BILLET_DOCTEST_TABLE=${table scenario}
      export PATH=${standIn}/bin:$PATH
      ${lib.concatMapStringsSep "\n" (dir: ''mkdir -p "$root/${dir}"'') directories}
      cd "$root/${scenario.cwd}"
      ${lib.concatMapStringsSep "\n" render scenario.steps}
    '';

  # Run a scenario with the session runner. The caller sets the root.
  command = scenario:
    lib.concatStringsSep " " ([
        "${doctest}/bin/billet-doctest"
        "session"
        "--timeout"
        (toString scenario.timeout)
      ]
      ++ lib.optionals (scenario.until != null) ["--until" (lib.escapeShellArg scenario.until)]
      ++ ["${script scenario}"]);

  mkScenario = attrs:
    {
      cwd = ".";
      until = null;
      timeout = 600;
      uses = [];
    }
    // attrs;
in {
  inherit parse coverage documents block materialize moduleBlock command mkScenario system;
  doc = name: (block name) // {doc = name;};
  harness = title: text: {
    inherit title;
    harness = text;
  };
  blocks = scenario: map (step: step.doc) (builtins.filter (step: step ? doc) scenario.steps);
  used = scenarios: lib.concatMap (scenario: map (step: step.doc) (builtins.filter (step: step ? doc) scenario.steps) ++ scenario.uses) scenarios;
}
