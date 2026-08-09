{
  facts,
  hostSpec,
  lib,
  ...
}:
let
  accounts = facts.accounts;
  resources = lib.filterAttrs (
    _: resource: resource.provider == hostSpec.name
  ) facts.shared-storage.resources;
  managedUserSpecs = lib.concatMap (
    resource:
    map (name: {
      inherit name;
      home = resource.path;
    }) (resource.identities.users or [ ])
  ) (builtins.attrValues resources);
  managedUserNames = map (spec: spec.name) managedUserSpecs;
  managedGroupNames = lib.unique (
    lib.concatMap (resource: resource.identities.groups or [ ]) (builtins.attrValues resources)
    ++ map (name: accounts.users.${name}.group) managedUserNames
  );
  managedGroups = builtins.listToAttrs (
    map (name: {
      inherit name;
      value.gid = accounts.groups.${name}.gid;
    }) managedGroupNames
  );
  managedUsers = builtins.listToAttrs (
    map (
      spec:
      let
        account = accounts.users.${spec.name};
      in
      {
        name = spec.name;
        value = {
          isSystemUser = true;
          inherit (account) group uid;
          inherit (spec) home;
          createHome = false;
        };
      }
    ) managedUserSpecs
  );
  directoryRules = lib.concatMap (
    directory:
    [
      "d ${directory.absolutePath} ${directory.mode} ${directory.owner} ${directory.group} - -"
    ]
    ++ lib.optional (directory.enforce or false) (
      "z ${directory.absolutePath} ${directory.mode} ${directory.owner} ${directory.group} - -"
    )
  ) (lib.concatMap (resource: resource.directories) (builtins.attrValues resources));
in
{
  users = {
    groups = managedGroups;
    users = managedUsers;
  };

  systemd.tmpfiles.rules = directoryRules;
}
