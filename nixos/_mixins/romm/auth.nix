{
  config,
  facts,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      facts
      lib
      outputs
      pkgs
      ;
  };
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
      mode = "oidc";
      oidcRegistration = {
        displayName = "RomM";
        originUrls = [ "${model.publicUrl}/api/oauth/openid" ];
        originLanding = "${model.publicUrl}/";
        allowInsecureClientDisablePkce = true;
        scopeMaps = lib.genAttrs model.accessGroups (_: model.oidcScopes ++ [ "romm_roles" ]);
        claimMaps.romm_roles.valuesByGroup = {
          ${ssoApplication.adminGroup} = [ ssoApplication.adminGroup ];
          ${ssoApplication.editorGroup} = [ ssoApplication.editorGroup ];
          ${ssoApplication.viewerGroup} = [ ssoApplication.viewerGroup ];
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
