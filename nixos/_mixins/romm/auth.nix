{
  lib,
  rommModel,
  ...
}:
let
  model = rommModel;
  inherit (model) cfg ssoApplication;
  restartUnits = [ "romm-setup.service" ] ++ model.units.containers;
in
{
  config = lib.mkIf (cfg != null && model.registrationReady) {
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
          owner = model.user;
          group = model.storageGroup;
          inherit restartUnits;
        };
      };
    };
  };
}
