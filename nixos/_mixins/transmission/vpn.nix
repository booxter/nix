{
  lib,
  transmissionModel,
  ...
}:
let
  model = transmissionModel;
  inherit (model) cfg;
in
{
  config = lib.mkIf (cfg != null && model.vpnNamespace != null) {
    host.vpn.clients.transmission = {
      namespace = model.vpnNamespaceName;
      bridgeTcpPorts = [ model.rpcPort ];
      forwardedPorts.peer = {
        port = cfg.vpn.peerPort;
        protocol = "both";
      };
    };

    services.nginx.virtualHosts."127.0.0.1:${toString model.rpcPort}" = {
      listen = lib.mkForce [
        {
          addr = "127.0.0.1";
          port = model.rpcPort;
        }
      ];
      locations."/" = {
        recommendedProxySettings = true;
        proxyWebsockets = true;
        proxyPass = lib.mkForce "http://${model.vpnNamespace.namespaceAddress}:${toString model.rpcPort}";
      };
    };
  };
}
