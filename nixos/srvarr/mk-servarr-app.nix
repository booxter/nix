{ config, lib }:
{
  addUserToApiGroup ? true,
  apiGroup ? null,
  name,
}:
let
  servarrCommon = import ./servarr-common.nix { inherit config lib; };
  stateDir = "${config.host.srvarrPaths.stateDir}/${name}";
  user = name;
in
lib.mkMerge [
  (servarrCommon.mkServarrService { inherit name; })
  {
    services.${name} = {
      dataDir = stateDir;
      user = user;
      group = "media";
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
  }
]
