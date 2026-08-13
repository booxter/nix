{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      pkgs
      ;
  };
  inherit (model) cfg ssoApplication service;
in
{
  config = lib.mkIf (cfg.enable && model.bootstrapReady) {
    host.web.services.pinepods.auth = {
      mode = "oidc";
      oidcRegistration = {
        displayName = "PinePods";
        originUrls = [ "${service.public.url}/api/auth/callback" ];
        originLanding = "${service.public.url}/";
        # TODO: Ask upstream to support PKCE for confidential OIDC clients.
        # PinePods 0.9.0 explicitly requires a confidential client without it.
        allowInsecureClientDisablePkce = true;
        scopeMaps = {
          ${ssoApplication.adminGroup} = model.oidcScopes ++ [ "pinepods_roles" ];
          ${ssoApplication.userGroup} = model.oidcScopes ++ [ "pinepods_roles" ];
        };
        claimMaps.pinepods_roles.valuesByGroup = {
          ${ssoApplication.adminGroup} = [ "admin" ];
          ${ssoApplication.userGroup} = [ "user" ];
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
