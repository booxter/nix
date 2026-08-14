{
  lib,
  rommModel,
  ...
}:
let
  model = rommModel;
  inherit (model) cfg ssoApplication;
  restartUnits = [
    "romm-setup.service"
    "podman-romm-api.service"
    "podman-romm-scheduler.service"
    "podman-romm-worker.service"
    "podman-romm-watcher.service"
  ];
in
{
  config = lib.mkIf (cfg.enable && model.registrationReady) {
    host.web.services.romm.auth = {
      oidcRegistration = {
        displayName = "RomM";
        originUrls = [ "${model.publicUrl}/api/oauth/openid" ];
        originLanding = "${model.publicUrl}/";
        allowInsecureClientDisablePkce = true;
        scopeMaps = lib.genAttrs model.accessGroups (_: model.oidcScopes ++ [ "romm_roles" ]);
        claimMaps.romm_roles.valuesByGroup = {
          ${ssoApplication.roles.admin} = [ ssoApplication.roles.admin ];
          ${ssoApplication.roles.editor} = [ ssoApplication.roles.editor ];
          ${ssoApplication.roles.viewer} = [ ssoApplication.roles.viewer ];
        };
        secret = {
          sopsKey = "romm/oidc/clientSecret";
          name = "romm/oidc/clientSecret";
          owner = cfg.user;
          group = model.storageGroup;
          inherit restartUnits;
        };
      };
    };
  };
}
