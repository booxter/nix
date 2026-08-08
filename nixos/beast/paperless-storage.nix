{
  config,
  hostInventory,
  ...
}:
let
  paperlessExportPath = hostInventory.storage.nfs.exports.paperless.path;
  paperlessUid = config.ids.uids.paperless;
  paperlessGid = config.ids.gids.paperless;
in
{
  users.groups.paperless.gid = paperlessGid;
  users.users.paperless = {
    isSystemUser = true;
    group = "paperless";
    uid = paperlessUid;
    home = paperlessExportPath;
    createHome = false;
  };

  systemd.tmpfiles.rules = [
    "d '${paperlessExportPath}' 0750 paperless paperless - -"
    "d '${paperlessExportPath}/consume' 0750 paperless paperless - -"
    "d '${paperlessExportPath}/export' 0750 paperless paperless - -"
    "d '${paperlessExportPath}/media' 0750 paperless paperless - -"
  ];
}
