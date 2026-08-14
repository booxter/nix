{
  config,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix { inherit config lib outputs; };
  inherit (model)
    cfg
    gptOauth2ProxyPort
    gptPort
    metricsInternalPort
    metricsMtlsPort
    paperlessService
    ssoApplication
    ;
in
{
  config = lib.mkIf (cfg != null) {
    host.web.services.paperless = {
      upstream = "http://127.0.0.1:${toString config.services.paperless.port}";
      public = {
        hostName = "papers.${config.host.network.publicDomain}";
        locationExtraConfig = ''
          client_max_body_size 512m;
          proxy_read_timeout 300s;
          proxy_send_timeout 300s;
        '';
      };
      health.frontend = {
        enable = true;
        path = "/accounts/login/";
      };
      displayName = "Paperless";
      dashboard = {
        enable = true;
        icon = "sh:paperless-ngx";
        section = "infrastructure";
      };
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
        enable = true;
        port = metricsMtlsPort;
        upstream = "http://127.0.0.1:${toString metricsInternalPort}/metrics";
      };
    };

    host.web.services.paperless-gpt = lib.mkIf (cfg.gpt != null) {
      upstream = "http://127.0.0.1:${toString gptPort}";
      health = {
        frontend = {
          enable = true;
          path = "/oauth2/sign_in";
        };
        backend = {
          enable = true;
          path = "/api/version";
        };
      };
      displayName = "Paperless GPT";
      dashboard = {
        enable = true;
        icon = "sh:paperless-ngx";
        section = "infrastructure";
      };
      auth = lib.mkIf (ssoApplication != null) {
        oauth2ProxyGate = {
          displayName = "Paperless GPT";
          port = gptOauth2ProxyPort;
          cookieName = "_paperless_gpt_sso";
          allowedGroups = [ ssoApplication.roles.admin ];
          groupClaim = "paperless_groups";
          internalHttpsServiceNames = [ "paperless-gpt" ];
        };
      };
    };
  };
}
