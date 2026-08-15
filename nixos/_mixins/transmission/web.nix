{ config, lib, ... }:
let
  cfg = config.host.transmission;
  rpcPort = config.services.transmission.settings.rpc-port;
  proxyHeaders = ''
    proxy_set_header Host ${config.networking.hostName};
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Server $hostname;
  '';
in
{
  config = lib.mkIf (cfg != null) {
    host.web.services.transmission = {
      upstream = "http://127.0.0.1:${toString rpcPort}";
      health = {
        frontend = {
          path = "/oauth2/sign_in";
        };
        backend = {
          path = "/__probe/transmission-rpc";
          module = "http_service_409";
          upstreamPath = "/transmission/rpc";
          recommendedProxySettings = false;
          allowedMethods = [ "GET" ];
          locationExtraConfig = proxyHeaders;
        };
      };
      displayName = "Transmission";
      dashboard = {
        section = "media-admin";
      };
      auth.policy = "media-admin";
      internal = {
        recommendedProxySettings = false;
        locationExtraConfig = proxyHeaders;
      };
    };
  };
}
