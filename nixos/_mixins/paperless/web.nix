{
  config,
  lib,
  paperlessModel,
  ...
}:
let
  inherit (paperlessModel)
    cfg
    metricsInternalPort
    paperlessService
    ;
in
{
  config = lib.mkIf (cfg != null) {
    host.web.services.paperless = {
      upstream = "http://127.0.0.1:${toString config.services.paperless.port}";
      internal = {
        recommendedProxySettings = false;
        locationExtraConfig = ''
          client_max_body_size 512m;
          proxy_set_header Host ${paperlessService.public.hostName};
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Forwarded-Host ${paperlessService.public.hostName};
          proxy_set_header X-Forwarded-Server $hostname;
          proxy_read_timeout 300s;
          proxy_send_timeout 300s;
        '';
      };
      metrics.default = {
        upstream = "http://127.0.0.1:${toString metricsInternalPort}/metrics";
      };
    };

  };
}
