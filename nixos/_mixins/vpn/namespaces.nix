{
  lib,
  vpnModel,
  ...
}:
let
  model = vpnModel;
in
{
  vpnNamespaces = lib.mapAttrs (
    namespaceName: namespace:
    let
      forwardedPorts = model.forwardedPorts.${namespaceName};
      portsFor =
        protocol:
        map (entry: entry.port) (
          lib.filter (entry: entry.protocol == protocol || entry.protocol == "both") forwardedPorts
        );
    in
    {
      inherit (namespace)
        allowedIngress
        bridgeAddress
        namespaceAddress
        wireguardConfigFile
        ;
      enable = true;
      vpn = {
        allowedTCPPorts = portsFor "tcp";
        allowedUDPPorts = portsFor "udp";
      };
    }
  ) model.cfg.namespaces;
}
