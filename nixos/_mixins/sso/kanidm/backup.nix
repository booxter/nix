{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.host.sso.provider;
  backupDir = "/var/lib/kanidm/backups";
in
{
  config = lib.mkIf cfg.enable {
    services.kanidm.server.settings.online_backup = {
      schedule = "15 03 * * *";
      versions = 14;
    };

    systemd.tmpfiles.rules = [
      "d ${backupDir} 0700 kanidm kanidm - -"
    ];

    host.backups.jobs.${hostInventory.backups.server.host}.paths = [ backupDir ];
  };
}
