{ config, lib }:
{
  addUserToApiGroup ? true,
  apiGroup ? null,
  name,
}:
let
  cfg = lib.getAttr name config.host.srvarr.services;
  serviceCfg = lib.getAttr name config.services;
in
{
  services.${name} = {
    enable = true;
    dataDir = cfg.stateDir;
    user = cfg.user;
    group = cfg.group;
    settings = {
      log.analyticsEnabled = false;
      server.bindaddress = "127.0.0.1";
      update = {
        automatically = false;
        mechanism = "external";
      };
    };
  };

  users = {
    groups = lib.optionalAttrs (apiGroup != null) {
      ${apiGroup} = { };
    };
    users.${cfg.user} =
      {
        isSystemUser = true;
      }
      // lib.optionalAttrs (apiGroup != null && addUserToApiGroup) {
        extraGroups = [ apiGroup ];
      };
  };

  host.internalHttps.services.${name} = {
    enable = true;
    upstream = "http://127.0.0.1:${toString serviceCfg.settings.server.port}";
  };
}
