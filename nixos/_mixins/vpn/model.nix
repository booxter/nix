{ config, lib }:
let
  cfg = config.host.vpn;
  enabledNamespaces = lib.filterAttrs (_: namespace: namespace.enable) cfg.namespaces;
  enabledClients = lib.filterAttrs (_: client: client.enable) cfg.clients;
  unknownNamespaces = lib.filterAttrs (
    _: client: !builtins.hasAttr client.namespace cfg.namespaces
  ) enabledClients;
  disabledNamespaces = lib.filterAttrs (
    _: client:
    builtins.hasAttr client.namespace cfg.namespaces && !cfg.namespaces.${client.namespace}.enable
  ) enabledClients;
  validClients = lib.filterAttrs (
    _: client: builtins.hasAttr client.namespace enabledNamespaces
  ) enabledClients;
  clientsByNamespace = builtins.groupBy (client: client.namespace) (builtins.attrValues validClients);
  clientsFor = namespaceName: clientsByNamespace.${namespaceName} or [ ];
in
{
  inherit
    cfg
    disabledNamespaces
    enabledClients
    enabledNamespaces
    unknownNamespaces
    validClients
    ;
  active = enabledNamespaces != { } || enabledClients != { };
  serviceNames = map (client: client.serviceName) (builtins.attrValues enabledClients);
  bridgeTcpPorts = lib.mapAttrs (
    namespaceName: _:
    lib.unique (lib.concatMap (client: client.bridgeTcpPorts) (clientsFor namespaceName))
  ) enabledNamespaces;
  forwardedPorts = lib.mapAttrs (
    namespaceName: _:
    lib.concatMap (client: builtins.attrValues client.forwardedPorts) (clientsFor namespaceName)
  ) enabledNamespaces;
}
