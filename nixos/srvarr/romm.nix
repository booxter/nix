{ config, lib, ... }:
let
  rommSso = config.host.sso.applications.romm;
  accessGroups = [
    rommSso.adminGroup
    rommSso.editorGroup
    rommSso.viewerGroup
  ];
  groupsFor = person: builtins.filter (group: builtins.elem group person.groups) accessGroups;
  mediaUsers = lib.filterAttrs (
    _: person: builtins.elem "media-users" person.groups
  ) config.host.sso.users;
in
{
  host.romm = {
    enable = true;
    publicHostName = "game.${config.host.network.publicDomain}";
    stateDir = "/data/.state/nixarr/romm";

    storage = {
      claim = "media";
      relativePath = "romm";
    };

    database.dataDir = "/data/.state/nixarr/mysql";
    backups.stagingDir = "/data/.state/nixarr/romm-mariadb-backup/latest";
    sso.application = "romm";
  };

  # Requiring every media user to have a RomM access tier is realm policy,
  # rather than a general invariant of the RomM service module.
  assertions = [
    {
      assertion = lib.all (person: builtins.length (groupsFor person) == 1) (
        builtins.attrValues mediaUsers
      );
      message = "Each media user must have exactly one RomM SSO access group.";
    }
  ];
}
