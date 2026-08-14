{ config, lib }:
let
  cfg = config.host.vpn;
  unknownNamespaces = lib.filterAttrs (
    _: client: !builtins.hasAttr client.namespace cfg.namespaces
  ) cfg.clients;
  validClients = lib.filterAttrs (
    _: client: builtins.hasAttr client.namespace cfg.namespaces
  ) cfg.clients;
  clientsByNamespace = builtins.groupBy (client: client.namespace) (builtins.attrValues validClients);
  clientsFor = namespaceName: clientsByNamespace.${namespaceName} or [ ];
in
{
  inherit
    cfg
    unknownNamespaces
    validClients
    ;
  active = cfg.namespaces != { } || cfg.clients != { };
  serviceNames = map (client: client.serviceName) (builtins.attrValues cfg.clients);
  bridgeTcpPorts = lib.mapAttrs (
    namespaceName: _:
    lib.unique (lib.concatMap (client: client.bridgeTcpPorts) (clientsFor namespaceName))
  ) cfg.namespaces;
  forwardedPorts = lib.mapAttrs (
    namespaceName: _:
    lib.concatMap (client: builtins.attrValues client.forwardedPorts) (clientsFor namespaceName)
  ) cfg.namespaces;
}
