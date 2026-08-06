{
  beastPkgs,
  config,
  hostInventory,
  lib,
  utils,
  ...
}:
let
  jellyfinBackupDir = "/var/lib/jellyfin/data/backups";
  stagingDir = "/volume2/backups/staging/jellyfin";
  keepLocalBackups = 7;
  keepJellyfinSourceBackups = 1;
  backupApiKeySecret = "jellyfin/apiKey";
  localRepoPasswordSecret = "backup/restic/beast/cloud/localPassword";
  localRepo = hostInventory.backups.clients.${config.networking.hostName}.repositoryPath;
  backupCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' beastPkgs.jellyfin-tools "jellyfin-built-in-backup")
    "--url"
    "http://127.0.0.1:8096"
    "--api-key-file"
    config.sops.secrets.${backupApiKeySecret}.path
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
  sops = {
    secrets = {
      ${backupApiKeySecret} = {
        owner = "root";
        group = "root";
        mode = "0400";
      };
    };
  };

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

  host.backups.jobs.beast = {
    title = "Beast Local Restic";
    user = "restic-cloud";
    repository = {
      type = "local";
      path = localRepo;
      passwordFile = config.sops.secrets.${localRepoPasswordSecret}.path;
      dependencyUnits = [ "sops-install-secrets.service" ];
    };
    preparations.jellyfin-built-in-backup = {
      service = "jellyfin-built-in-backup";
      title = "Jellyfin Built-In Backup";
      paths = [ stagingDir ];
    };
    timerConfig = {
      OnCalendar = "04:45";
      RandomizedDelaySec = "5m";
      Persistent = true;
    };
  };
}
