{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
in
{
  config = lib.mkIf (cfg != null) {
    services.nginx.commonHttpConfig = ''
      map $http_x_forwarded_host $audiobookshelf_proxy_host {
          default $http_x_forwarded_host;
          "" $host;
      }

      map $http_x_forwarded_proto $audiobookshelf_proxy_proto {
          default $http_x_forwarded_proto;
          "" $scheme;
      }
    '';

    host.web.services.audiobookshelf = {
      upstream = "http://127.0.0.1:${toString cfg.port}";
      public = {
        enable = true;
        hostName = cfg.publicHostName;
      };
      health.frontend = {
        enable = true;
        path = "";
      };
      observability.importance = "important";
      dashboard = {
        enable = true;
        section = "user";
      };
      internal = {
        recommendedProxySettings = false;
        locationExtraConfig = ''
          proxy_set_header Host $audiobookshelf_proxy_host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $audiobookshelf_proxy_proto;
          proxy_set_header X-Forwarded-Host $audiobookshelf_proxy_host;
          proxy_set_header X-Forwarded-Server $hostname;
        '';
      };
    };
  };
}
