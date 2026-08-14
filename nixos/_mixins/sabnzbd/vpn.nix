{
  config,
  lib,
  storageModel,
  ...
}:
let
  model = import ./model.nix { inherit config lib storageModel; };
  inherit (model) cfg;
in
{
  config = lib.mkIf (cfg.enable && model.vpnNamespace != null) {
    host.vpn.clients.sabnzbd = {
      namespace = cfg.vpn.namespace;
      bridgeTcpPorts = [ cfg.port ];
    };

    services.nginx.virtualHosts."127.0.0.1:${toString cfg.port}" = {
      listen = lib.mkForce [
        {
          addr = "127.0.0.1";
          port = cfg.port;
        }
      ];
      locations."/" = {
        recommendedProxySettings = true;
        proxyWebsockets = true;
        proxyPass = lib.mkForce "http://${model.vpnNamespace.namespaceAddress}:${toString cfg.port}";
      };
    };
  };
}
