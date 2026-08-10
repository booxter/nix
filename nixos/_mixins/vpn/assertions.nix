{ config, lib, ... }:
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
  serviceNames = map (client: client.serviceName) (builtins.attrValues enabledClients);
in
{
  assertions = lib.optionals (enabledNamespaces != { } || enabledClients != { }) [
    {
      assertion = unknownNamespaces == { };
      message = "host.vpn.clients reference unknown namespaces: ${lib.concatStringsSep ", " (builtins.attrNames unknownNamespaces)}";
    }
    {
      assertion = disabledNamespaces == { };
      message = "host.vpn.clients reference disabled namespaces: ${lib.concatStringsSep ", " (builtins.attrNames disabledNamespaces)}";
    }
    {
      assertion = builtins.length serviceNames == builtins.length (lib.unique serviceNames);
      message = "host.vpn.clients must use unique systemd service names";
    }
  ];
}
