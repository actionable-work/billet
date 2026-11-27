{lib}: members: let
  diagnostic = code: field: reason: {
    inherit code field reason;
    capability = "directional-private-network-policy";
    severity = "error";
  };
in
  lib.concatLists (lib.mapAttrsToList (name: ir:
    lib.concatLists (lib.imap0 (index: link: let
      destination = members.${link.destinationService} or null;
      port =
        if destination == null
        then null
        else destination.network.ports.${link.destinationPort} or null;
      field = "services.${name}.network.privateConnections.${toString index}";
    in
      lib.optional (destination != null && port == null)
      (diagnostic "BundlePrivateConnectionPort" "${field}.destinationPort" "port is missing from the bundle destination")
      ++ lib.optional (port != null && port.protocol != link.protocol)
      (diagnostic "BundlePrivateConnectionProtocol" "${field}.protocol" "protocol differs from the bundle destination port"))
    ir.network.privateConnections))
  members)
