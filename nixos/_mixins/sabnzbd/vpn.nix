{
  lib,
  sabnzbdModel,
  ...
}:
let
  model = sabnzbdModel;
  inherit (model) cfg;
in
{
  config = lib.mkIf (cfg != null && model.vpnNamespace != null) {
    host.vpn.clients.sabnzbd = {
      namespace = "wg";
      bridgeTcpPorts = [ model.port ];
    };

    services.nginx.virtualHosts."127.0.0.1:${toString model.port}" = {
      listen = lib.mkForce [
        {
          addr = "127.0.0.1";
          port = model.port;
        }
      ];
      locations."/" = {
        recommendedProxySettings = true;
        proxyWebsockets = true;
        proxyPass = lib.mkForce "http://${model.vpnNamespace.namespaceAddress}:${toString model.port}";
      };
    };
  };
}
