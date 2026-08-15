{
  lib,
  pinepodsModel,
  ...
}:
let
  inherit (pinepodsModel) cfg ssoApplication service;
in
{
  config = lib.mkIf (cfg != null && pinepodsModel.bootstrapReady) {
    host.web.services.pinepods.auth = {
      oidcRegistration = {
        displayName = "PinePods";
        originUrls = [ "${service.public.url}/api/auth/callback" ];
        originLanding = "${service.public.url}/";
        # TODO: Ask upstream to support PKCE for confidential OIDC clients.
        # PinePods 0.9.0 explicitly requires a confidential client without it.
        allowInsecureClientDisablePkce = true;
        scopeMaps = {
          ${ssoApplication.roles.admin} = pinepodsModel.oidcScopes ++ [ "pinepods_roles" ];
          ${ssoApplication.roles.user} = pinepodsModel.oidcScopes ++ [ "pinepods_roles" ];
        };
        claimMaps.pinepods_roles.valuesByGroup = {
          ${ssoApplication.roles.admin} = [ "admin" ];
          ${ssoApplication.roles.user} = [ "user" ];
        };
        secret = {
          sopsKey = "pinepods/oidc/client_secret";
          name = "pinepods/oidc/client_secret";
          restartUnits = [ "podman-pinepods.service" ];
        };
      };
    };
  };
}
