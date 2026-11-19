{
  lib,
  ir,
  name,
  labels,
  labelsFor,
  hash,
  warning,
}: let
  inherit (ir) network;
  portName = logical: protocol: "p-${builtins.substring 0 13 (hash [logical protocol])}";
  namedPorts = lib.mapAttrs (logical: p: p // {name = portName logical p.protocol;}) network.ports;
  allPorts = builtins.attrValues namedPorts;
  publicPorts = builtins.filter (p: p.exposure == "public") allPorts;
  policyPort = value: {
    port = value;
    protocol = "TCP";
  };
  service = type: resourceName: selectedPorts: {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      name = resourceName;
      inherit labels;
    };
    spec = {
      inherit type;
      selector = labels;
      ports = map (p:
        policyPort p.port
        // {
          inherit (p) name;
          targetPort = p.name;
        })
      selectedPorts;
    };
  };
  services =
    lib.optional (allPorts != []) (service "ClusterIP" name allPorts)
    ++ lib.optional (publicPorts != []) (service "LoadBalancer" "billet-public-${builtins.substring 0 49 (hash ir.identity.name)}" publicPorts);

  incoming = link: link.destinationService == ir.identity.name;
  outgoing = link: link.sourceService == ir.identity.name;
  validLocalPort = link:
    builtins.hasAttr link.destinationPort namedPorts
    && namedPorts.${link.destinationPort}.protocol == link.protocol;
  ingressLinks = builtins.filter (link: incoming link && validLocalPort link) network.privateConnections;
  egressLinks = builtins.filter (link: outgoing link && (!incoming link || validLocalPort link)) network.privateConnections;
  peer = value: {podSelector.matchLabels = labelsFor value;};
  isolateIngress = allPorts != [] || builtins.any incoming network.privateConnections;
  isolateEgress = !network.publicEgress;
  policy = {
    apiVersion = "networking.k8s.io/v1";
    kind = "NetworkPolicy";
    metadata = {inherit name labels;};
    spec =
      {
        podSelector.matchLabels = labels;
        policyTypes = lib.optional isolateIngress "Ingress" ++ lib.optional isolateEgress "Egress";
      }
      // lib.optionalAttrs isolateIngress {
        ingress =
          lib.optional (publicPorts != []) {ports = map (p: policyPort p.port) publicPorts;}
          ++ map (link: {
            from = [(peer link.sourceService)];
            ports = [(policyPort namedPorts.${link.destinationPort}.port)];
          })
          ingressLinks;
      }
      // lib.optionalAttrs isolateEgress {
        egress =
          map (link: {
            to = [(peer link.destinationService)];
            ports = [(policyPort (portName link.destinationPort link.protocol))];
          })
          egressLinks;
      };
  };
in {
  ports =
    map (p: {
      inherit (p) name;
      containerPort = p.port;
      protocol = "TCP";
    })
    allPorts;
  items = services ++ lib.optional (isolateIngress || isolateEgress) policy;
  supportedCapabilities =
    lib.optional (allPorts != []) "network-ports"
    ++ lib.optional (ingressLinks != [] || (isolateEgress && egressLinks != [])) "same-namespace-private-connections"
    ++ lib.optional isolateEgress "egress-isolation";
  diagnostics =
    lib.optional isolateEgress
    (warning "KubernetesEgressDNS" "egress-policy" "network.publicEgress" "egress isolation also blocks DNS unless the cluster supplies a DNS allow policy")
    ++ lib.optional (network.egressRestrictions != [])
    (warning "KubernetesEgressRestrictions" "egress-policy" "network.egressRestrictions" "opaque restrictions have no native network policy mapping")
    ++ lib.concatLists (lib.imap0 (index: link:
      lib.optional (incoming link && !validLocalPort link)
      (warning "KubernetesPrivateConnectionPort" "directional-private-network-policy" "network.privateConnections.${toString index}.destinationPort" "the local destination port must exist and match the declared protocol"))
    network.privateConnections);
}
