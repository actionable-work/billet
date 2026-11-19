{
  pkgs,
  billets,
  members,
  system,
  structureDiagnostics,
  microvm,
  settings,
}: let
  inherit (pkgs) lib;
  names = builtins.attrNames members;
  services = lib.mapAttrs (_: billet: billet.microvm.capabilityReport) billets;
  sorted = values: lib.sort builtins.lessThan (lib.unique values);
  field = name: "services.${name}.network.privateConnections";
  diagnostic = severity: code: fieldPath: reason: {
    inherit severity code reason;
    field = fieldPath;
    capability = "microvm-packaging";
  };
  error = diagnostic "error";
  warning = diagnostic "warning";
  validName = name:
    name
    != "localhost"
    && builtins.stringLength name <= 63
    && builtins.match "[a-z]([-a-z0-9]*[a-z0-9])?" name != null;
  declarations = lib.concatLists (lib.mapAttrsToList (name: ir:
    map (link: {inherit name link;}) ir.network.privateConnections)
  members);
  links = lib.unique (map (declaration: declaration.link) declarations);
  inBundle = link: builtins.hasAttr link.sourceService members && builtins.hasAttr link.destinationService members;
  internalLinks = builtins.filter inBundle links;
  destinationPort = link: members.${link.destinationService}.network.ports.${link.destinationPort} or null;
  validLink = link:
    link.sourceService
    != link.destinationService
    && destinationPort link != null
    && (destinationPort link).protocol == link.protocol;
  mappedLinks = builtins.filter validLink internalLinks;
  destinations = sorted (map (link: link.destinationService) mappedLinks);
  connected = sorted (map (link: link.sourceService) mappedLinks ++ destinations);
  bindingKey = link: builtins.toJSON [link.destinationService link.destinationPort];
  bindings = sorted (map bindingKey mappedLinks);
  validSettings = builtins.isAttrs settings && builtins.all (key: key == "hostPortBase") (builtins.attrNames settings);
  basePort =
    if validSettings
    then settings.hostPortBase or 18080
    else null;
  validPorts = builtins.isInt basePort && basePort >= 1024 && basePort <= 65535 && builtins.length bindings <= 65536 - basePort;
  errors =
    map (item:
      item
      // {
        severity = "error";
        capability = "microvm-packaging";
      })
    structureDiagnostics
    ++ map (name: error "MicrovmBundleMemberName" "services.${name}.identity.name" "a bundle member name must be a lowercase DNS label starting with a letter and distinct from localhost") (builtins.filter (name: !validName name) names)
    ++ lib.concatMap ({
      name,
      link,
    }:
      lib.optional (inBundle link && !validLink link)
      (error "MicrovmBundleLink" (field name) "a link needs a distinct destination with a matching declared port and protocol"))
    declarations
    ++ lib.optional (!validSettings) (error "MicrovmBundleSettings" "microvm" "bundle settings accept hostPortBase")
    ++ lib.optional (validSettings && !validPorts) (error "MicrovmBundleHostPorts" "microvm.hostPortBase" "the allocated loopback ports must fit in 1024..65535")
    ++ lib.optional (builtins.length destinations > 155) (error "MicrovmBundleAddresses" "services" "QEMU user networks can map at most 155 distinct bundle destinations")
    ++ lib.concatMap (name: let
      inherit (members.${name}) network;
    in
      lib.optional (!network.publicEgress || network.egressRestrictions != [])
      (error "MicrovmBundleEgress" "services.${name}.network.${
        if network.publicEgress
        then "egressRestrictions"
        else "publicEgress"
      }" "QEMU user networking requires consumer wiring for restrictive egress"))
    connected;
  diagnostics =
    errors
    ++ lib.concatMap ({
      name,
      link,
    }:
      lib.optional (!inBundle link)
      (warning "MicrovmBundleExternalLink" (field name) "a connection to an outside service requires consumer wiring"))
    declarations
    ++ lib.concatLists (lib.mapAttrsToList (name: report:
      map (item: item // {field = "services.${name}.${item.field}";}) report.diagnostics)
    services);
  reports = builtins.attrValues services;
  canRender = errors == [] && builtins.all (report: report.canRender) reports;
  requireRenderable = value:
    if canRender
    then value
    else throw ("billet: UnsupportedTarget microvm: " + lib.concatMapStringsSep "; " (item: "${item.field}: ${item.reason}") (builtins.filter (item: item.severity == "error") diagnostics));
  assignments = values: valueAt:
    builtins.listToAttrs (lib.imap0 (i: name: {
        inherit name;
        value = valueAt i;
      })
      values);
  portAssignments = assignments bindings (i: basePort + i);
  addressAssignments = assignments destinations (i: "10.0.2.${toString (100 + i)}");
  routes =
    map (link: {
      inherit (link) sourceService destinationService destinationPort protocol;
      port = (destinationPort link).port;
      address = addressAssignments.${link.destinationService};
      hostPort = portAssignments.${bindingKey link};
    })
    mappedLinks;
  guestSettings = name: billet: let
    incoming = builtins.filter (route: route.destinationService == name) routes;
    outgoing = builtins.filter (route: route.sourceService == name) routes;
    identityHash = builtins.hashString "sha256" name;
    mac = lib.concatStringsSep ":" (["02"] ++ map (i: builtins.substring i 2 identityHash) [0 2 4 6 8]);
    forward = from: route: {
      inherit from;
      guest = {inherit (route) port;} // lib.optionalAttrs (from == "guest") {inherit (route) address;};
      host = {
        address = "127.0.0.1";
        port = route.hostPort;
      };
    };
    networked = {
      microvm.interfaces = [
        {
          type = "user";
          id = "billet-lan";
          inherit mac;
        }
      ];
      microvm.forwardPorts = lib.unique (map (forward "host") incoming) ++ map (forward "guest") outgoing;
      networking = {
        hostName = name;
        useDHCP = false;
        firewall.allowedTCPPorts = lib.unique (map (route: route.port) incoming);
        hosts = builtins.listToAttrs (map (route: {
            name = route.address;
            value = [route.destinationService];
          })
          outgoing);
      };
      systemd.network = {
        wait-online.enable = true;
        networks."10-billet-lan" = {
          matchConfig.MACAddress = mac;
          networkConfig.DHCP = "ipv4";
          linkConfig.RequiredForOnline = "routable";
        };
      };
      systemd.services.billet = {
        wants = ["network-online.target"];
        after = ["network-online.target"];
      };
    };
  in
    lib.recursiveUpdate billet.microvm.configuration (
      if incoming != [] || outgoing != []
      then networked
      else {networking.hostName = name;}
    );
  configuration = requireRenderable {
    schemaVersion = 1;
    inherit system routes;
    services =
      lib.mapAttrs (name: billet: {
        guest = guestSettings name billet;
        runner = "guests/${name}/runner";
        manifest = "manifests/${name}.json";
        manifestDigest = builtins.unsafeDiscardStringContext billet.manifestDigest;
      })
      billets;
  };
  evaluateGuest = import ./microvm-guest.nix {inherit pkgs microvm;};
  guests = lib.mapAttrs (_: service: evaluateGuest [service.guest]) configuration.services;
  file = pkgs.writeText "microvm.json" (builtins.unsafeDiscardStringContext (builtins.toJSON configuration) + "\n");
in {
  inherit configuration file;
  capabilityReport = {
    schemaVersion = 1;
    target = "microvm";
    profile = "microvm-artifact-bundle-v1";
    profileVersion = 1;
    rendererVersion = 1;
    mode = "artifact-only";
    inherit system diagnostics canRender services;
    requiredCapabilities = sorted (lib.concatMap (report: report.requiredCapabilities) reports);
    supportedCapabilities = lib.optionals canRender (sorted (
      lib.concatMap (report: report.supportedCapabilities) reports ++ lib.optional (mappedLinks != []) "loopback-private-links"
    ));
  };
  hostModule = requireRenderable {
    imports = [(microvm.outPath + "/nixos-modules/host")];
    microvm.vms = lib.mapAttrs (_: evaluatedConfig: {inherit evaluatedConfig;}) guests;
  };
  bundle = requireRenderable (pkgs.runCommand "billet-microvm-bundle-v1" {} ''
    mkdir -p "$out/manifests" "$out/guests"
    cp ${file} "$out/microvm.json"
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: guest: ''
        mkdir "$out/guests/${name}"
        ln -s ${guest.config.microvm.declaredRunner} "$out/guests/${name}/runner"
        cp ${billets.${name}.manifest} "$out/manifests/${name}.json"
      '')
      guests)}
  '');
}
