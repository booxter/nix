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
      bridgeTcpPorts = [ 6336 ];
    };

    services.nginx.virtualHosts."127.0.0.1:6336" = {
      listen = lib.mkForce [
        {
          addr = "127.0.0.1";
          port = 6336;
        }
      ];
      locations."/" = {
        recommendedProxySettings = true;
        proxyWebsockets = true;
        proxyPass = lib.mkForce "http://${model.vpnNamespace.namespaceAddress}:6336";
      };
    };
  };
}
