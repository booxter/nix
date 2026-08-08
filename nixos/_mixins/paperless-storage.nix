{
  config,
  hostInventory,
  lib,
  ...
}:
let
  paperlessAccount = hostInventory.serviceAccounts.paperless;
  paperlessExport = hostInventory.storage.nfs.exports.paperless;
  projectPaths = builtins.mapAttrs (
    _: value: "${paperlessExport.path}/${value}"
  ) paperlessExport.layout;
in
{
  config = lib.mkIf (paperlessExport.server == config.networking.hostName) {
    users.groups.paperless.gid = paperlessAccount.gid;
    users.users.paperless = {
      isSystemUser = true;
      group = "paperless";
      uid = paperlessAccount.uid;
      home = paperlessExport.path;
      createHome = false;
    };

    systemd.tmpfiles.rules = map (path: "d '${path}' 0750 paperless paperless - -") (
      [ paperlessExport.path ] ++ builtins.attrValues projectPaths
    );
  };
}
