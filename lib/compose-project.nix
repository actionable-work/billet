{lib}: members: let
  inherit (builtins) attrValues;
  internal = lib.any (ir: !ir.network.publicEgress) (attrValues members);
  egress = lib.any (ir: ir.network.publicEgress) (attrValues members);
  connections = lib.concatMap (ir: ir.network.privateConnections) (attrValues members);
  candidates = lib.groupBy (link: link.sourceService) (builtins.filter (link: let
    destination = members.${link.destinationService} or null;
  in
    builtins.hasAttr link.sourceService members
    && link.sourceService != link.destinationService
    && destination != null
    && builtins.hasAttr link.destinationPort destination.network.ports
    && destination.resources.replicas.min > 0
    && (destination.probes.readiness.type or null) == "exec")
  connections);
  graph = lib.mapAttrs (_: links: lib.unique (map (link: link.destinationService) links)) candidates;
  reaches = start: destination:
    lib.any (node: node.key == destination) (builtins.genericClosure {
      startSet = [{key = start;}];
      operator = node: map (key: {inherit key;}) (graph.${node.key} or []);
    });
  dependencies = lib.mapAttrs (source: builtins.filter (destination: !reaches destination source)) graph;
  hasDependencies = lib.any (destinations: destinations != []) (attrValues dependencies);
in {
  configure = services:
    {
      services = lib.mapAttrs (name: service: let
        ir = members.${name};
        destinations = dependencies.${name} or [];
      in
        service
        // lib.optionalAttrs internal {
          networks = {billet-internal = {};} // lib.optionalAttrs ir.network.publicEgress {billet-egress.gw_priority = 1;};
        }
        // lib.optionalAttrs (destinations != []) {
          depends_on = lib.genAttrs destinations (_: {condition = "service_healthy";});
        })
      services;
    }
    // lib.optionalAttrs internal {
      networks = {billet-internal.internal = true;} // lib.optionalAttrs egress {billet-egress = {};};
    };
  diagnostics = lib.concatLists (lib.mapAttrsToList (source: destinations:
    lib.optional (destinations != dependencies.${source}) {
      code = "ComposeReadinessCycle";
      field = "services.${source}.network.privateConnections";
      capability = "readiness-dependencies";
      reason = "Compose startup ordering omits readiness dependencies that form a cycle";
      severity = "warning";
    })
  graph);
  supportedCapabilities = lib.optional hasDependencies "readiness-dependencies";
}
