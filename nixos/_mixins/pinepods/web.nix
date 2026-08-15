{
  config,
  lib,
  pinepodsModel,
  ...
}:
let
  inherit (pinepodsModel) cfg port;
  service = config.host.web.services.pinepods;
  hostName = "pod.${config.host.network.publicDomain}";
in
{
  config = lib.mkIf (cfg != null) {
    host.web.services.pinepods = {
      upstream = "http://127.0.0.1:${toString port}";
      public = { inherit hostName; };
      health = {
        frontend = {
          path = "/api/health";
        };
        backend = {
          path = "/api/health";
        };
      };
      observability.importance = "best-effort";
      displayName = "PinePods";
      dashboard = {
        icon = "sh:pinepods";
        section = "user";
      };
      internal = {
        recommendedProxySettings = false;
        locationExtraConfig = ''
          proxy_set_header Host ${service.public.hostName};
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto https;
          proxy_set_header X-Forwarded-Host ${service.public.hostName};
          proxy_set_header X-Forwarded-Server $hostname;
          proxy_read_timeout 300s;
          proxy_send_timeout 300s;
        '';
      };
    };
  };
}
