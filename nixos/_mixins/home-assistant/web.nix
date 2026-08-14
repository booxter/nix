{
  config,
  lib,
  ...
}:
let
  cfg = config.host.home-assistant;
  homeAssistantSso = config.host.sso.applications.home-assistant;
  oidcScopes = config.host.sso.oidc.baseScopes;
  hostName = "home.${config.host.network.lanDomain}";
in
{
  config = lib.mkIf cfg.enable {
    host.web.services.home = {
      upstream = cfg.localUrl;
      auth = {
        oidcRegistration = {
          displayName = "Home Assistant";
          public = true;
          originUrls = [
            "https://${hostName}/auth/oidc/welcome"
            "https://${hostName}/auth/oidc/callback"
          ];
          originLanding = "https://${hostName}/";
          scopeMaps = {
            ${homeAssistantSso.adminGroup} = oidcScopes ++ [ "home_groups" ];
            ${homeAssistantSso.userGroup} = oidcScopes ++ [ "home_groups" ];
          };
          claimMaps.home_groups.valuesByGroup = {
            ${homeAssistantSso.adminGroup} = [ homeAssistantSso.adminGroup ];
            ${homeAssistantSso.userGroup} = [ homeAssistantSso.userGroup ];
          };
        };
      };
      health.frontend.enable = true;
      displayName = "Home Assistant";
      dashboard = {
        enable = true;
        icon = "sh:home-assistant";
        section = "infrastructure";
      };
      internal.locationExtraConfig = ''
        proxy_buffering off;
        proxy_read_timeout 3600s;
      '';
      metrics.default = {
        enable = true;
        endpointName = "home-assistant";
        jobName = "home-assistant";
        port = cfg.metrics.port;
        upstream = "${cfg.localUrl}/api/prometheus";
      };
    };
  };
}
