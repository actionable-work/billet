{lib}: network: code:
lib.concatLists (lib.mapAttrsToList (direction: rates:
    lib.mapAttrsToList (bound: _: {
      inherit code;
      severity = "warning";
      field = "network.bandwidth.${direction}.${bound}";
      capability =
        if bound == "minBitsPerSecond"
        then "network-bandwidth-reservations"
        else "network-bandwidth-limits";
      reason = "bandwidth enforcement requires consumer-managed networking";
    })
    rates)
(network.bandwidth or {}))
