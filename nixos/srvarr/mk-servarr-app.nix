{ config, lib }:
{
  addUserToApiGroup ? true,
  apiGroup ? null,
  name,
}:
let
  servarrCommon = import ./servarr-common.nix { inherit config lib; };
  stateDir = "/data/.state/nixarr/${name}";
  user = name;
in
lib.mkMerge [
  (servarrCommon.mkServarrService { inherit name; })
  {
    host.storage.claims.media.attachments.${name}.unit = name;

    host.backups.sources.${name} = {
      title = lib.strings.toSentenceCase name;
      capture.type = "scheduled";
      capture.scheduled.outputPaths = [ "${stateDir}/Backups" ];
    };

    services.${name} = {
      dataDir = stateDir;
      user = user;
      group = "media";
    };

    systemd.services.${name}.serviceConfig.UMask = lib.mkForce "0002";

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
