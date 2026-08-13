{ config, lib, ... }:
let
  cfg = config.host.transmission;
  rpcPort = config.services.transmission.settings.rpc-port;
in
{
  config = lib.mkIf cfg.enable {
    host.web.services.transmission = {
      upstream = "http://127.0.0.1:${toString rpcPort}";
      health = {
        frontend = {
          enable = true;
          path = "/oauth2/sign_in";
        };
        backend = {
          enable = true;
          path = "/__probe/transmission-rpc";
          module = "http_service_409";
        };
      };
      displayName = "Transmission";
      dashboard = {
        enable = true;
        section = "media-admin";
      };
      internal = {
        recommendedProxySettings = false;
        locationExtraConfig = ''
          proxy_set_header Host ${config.networking.hostName};
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Forwarded-Host $host;
          proxy_set_header X-Forwarded-Server $hostname;
        '';
      };
    };
  };
}
