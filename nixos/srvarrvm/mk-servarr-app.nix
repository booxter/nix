{ config, lib }:
{
  addUserToApiGroup ? true,
  apiGroup ? null,
  name,
}:
let
  stateDir = "${config.host.srvarrPaths.stateDir}/${name}";
  serviceCfg = lib.getAttr name config.services;
  user = name;
in
{
  services.${name} = {
    enable = true;
    dataDir = stateDir;
    user = user;
    group = "media";
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
    users.${user} = {
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
