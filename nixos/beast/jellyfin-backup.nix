{
  beastPkgs,
  config,
  lib,
  utils,
  ...
}:
let
  jellyfinBackupDir = "/var/lib/jellyfin/data/backups";
  stagingDir = "${config.host.storage.volumes.data.mounts.data.mountPoint}/backups/staging/jellyfin";
  keepLocalBackups = 7;
  keepJellyfinSourceBackups = 1;
  backupCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' beastPkgs.jellyfin-tools "jellyfin-built-in-backup")
    "--url"
    "http://127.0.0.1:8096"
    "--api-key-file"
    config.services.jellyfin.apiKey.file
    "--source-dir"
    jellyfinBackupDir
    "--staging-dir"
    stagingDir
    "--keep-staging"
    (toString keepLocalBackups)
    "--keep-source"
    (toString keepJellyfinSourceBackups)
  ];
in
{
  systemd.tmpfiles.rules = [
    "d ${stagingDir} 0750 root restic-cloud - -"
  ];

  systemd.services.jellyfin-built-in-backup = {
    description = "Create a built-in Jellyfin backup archive";
    restartIfChanged = false;
    stopIfChanged = false;
    wants = [
      "jellyfin.service"
      "sops-install-secrets.service"
    ];
    after = [
      "jellyfin.service"
      "sops-install-secrets.service"
    ];
    unitConfig.RequiresMountsFor = [
      jellyfinBackupDir
      stagingDir
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "restic-cloud";
      UMask = "0027";
      ExecStart = backupCommand;
    };
  };

  host.backups.jobs.beast.preparations.jellyfin-built-in-backup = {
    service = "jellyfin-built-in-backup";
    title = "Jellyfin Built-In Backup";
    paths = [ stagingDir ];
  };
}
