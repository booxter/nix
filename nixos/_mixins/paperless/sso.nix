{
  config,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix { inherit config lib outputs; };
  inherit (model) cfg paperlessService ssoApplication;
  oidcScopes = config.host.sso.oidc.baseScopes;
in
{
  config = lib.mkIf (cfg.enable && ssoApplication != null) {
    host.web.services.paperless.auth = {
      oidcRegistration = {
        displayName = "Paperless";
        originUrls = [ "${paperlessService.public.url}/accounts/oidc/sso/login/callback/" ];
        originLanding = "${paperlessService.public.url}/";
        scopeMaps = {
          ${ssoApplication.roles.admin} = oidcScopes ++ [ "groups" ];
          ${ssoApplication.roles.user} = oidcScopes ++ [ "groups" ];
        };
        claimMaps.groups.valuesByGroup = {
          ${ssoApplication.roles.admin} = [ ssoApplication.roles.admin ];
          ${ssoApplication.roles.user} = [ ssoApplication.roles.user ];
        };
        secret = {
          sopsKey = "paperless/oidc/client_secret";
          name = "paperless/oidc/client_secret";
          restartUnits = [
            "paperless-scheduler.service"
            "paperless-task-queue.service"
            "paperless-web.service"
          ];
        };
      };
    };
  };
}
