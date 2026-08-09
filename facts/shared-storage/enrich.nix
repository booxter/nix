{ accounts, lib }:
facts:
let
  normalizeDirectory =
    resourceName: resource: directory:
    let
      ownerAccount = accounts.users.${directory.owner} or null;
      owner =
        if ownerAccount != null then
          toString ownerAccount.uid
        else if directory.owner == "root" then
          "root"
        else
          throw "shared storage ${resourceName} directory '${directory.path}' references unknown owner '${directory.owner}'";
      group =
        if builtins.hasAttr directory.group accounts.groups || directory.group == "root" then
          directory.group
        else
          throw "shared storage ${resourceName} directory '${directory.path}' references unknown group '${directory.group}'";
      absolutePath =
        if directory.path == "." then resource.path else "${resource.path}/${directory.path}";
    in
    directory
    // {
      inherit absolutePath group owner;
    };
in
facts
// {
  resources = lib.mapAttrs (
    resourceName: resource:
    resource
    // {
      inherit resourceName;
      directories = map (normalizeDirectory resourceName resource) resource.directories;
    }
  ) facts.resources;
}
