{
  config,
  lib,
  watchstateModel,
  ...
}:
let
  inherit (watchstateModel) cfg localUrl;
  sso = config.host.sso.applications.watchstate;
in
{
  config = lib.mkIf (cfg != null) {
    host.web.services.watchstate = {
      upstream = localUrl;
      health = {
        frontend = {
          path = "/oauth2/sign_in";
        };
        backend = {
          path = "/v1/api/system/healthcheck";
        };
      };
      displayName = "WatchState";
      dashboard = {
        icon = "sh:watchstate.png";
        section = "media-admin";
      };
      internal.locationExtraConfig = ''
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
      '';
      auth = {
        oauth2ProxyGate = {
          displayName = "WatchState";
          port = 4182;
          cookieName = "_watchstate_sso";
          allowedGroups = [ sso.roles.admin ];
          groupClaim = "media_groups";
          internalHttpsServiceNames = [ "watchstate" ];
          authRequestHeaders = { };
          clearAuthorizationHeader = false;
        };
      };
    };
  };
}
