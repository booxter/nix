{
  config,
  lib,
  utils,
  ...
}:
let
  jellyfinCfg = config.services.jellyfin;
  cfg = jellyfinCfg.builtInBackup;
  backupCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' cfg.package "jellyfin-built-in-backup")
    "--url"
    cfg.jellyfinUrl
    "--api-key-file"
    jellyfinCfg.apiKey.file
    "--source-dir"
    cfg.sourceDir
    "--staging-dir"
    cfg.stagingDir
    "--keep-staging"
    (toString cfg.keepStaging)
    "--keep-source"
    (toString cfg.keepSource)
  ];
in
{
  options.services.jellyfin.builtInBackup = {
    enable = lib.mkEnableOption "Jellyfin built-in backup preparation";

    package = lib.mkOption {
      type = lib.types.package;
      default = jellyfinCfg.tools.package;
      description = "Package providing the Jellyfin backup helper.";
    };

    jellyfinUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8096";
      description = "Jellyfin API URL used to request a built-in backup.";
    };

    sourceDir = lib.mkOption {
      type = lib.types.path;
      default = "${jellyfinCfg.dataDir}/data/backups";
      description = "Directory in which Jellyfin creates built-in backups.";
    };

    stagingDir = lib.mkOption {
      type = lib.types.path;
      description = "Directory staging built-in backups for the host backup job.";
    };

    keepStaging = lib.mkOption {
      type = lib.types.ints.positive;
      default = 7;
      description = "Number of built-in backups retained in the staging directory.";
    };

    keepSource = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Number of built-in backups retained in Jellyfin's data directory.";
    };

    backupJob = lib.mkOption {
      type = lib.types.str;
      description = "Host backup job that includes the staged Jellyfin backup.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      description = "Group permitted to read the staged backup.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = jellyfinCfg.enable;
        message = "services.jellyfin.builtInBackup requires services.jellyfin.enable.";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.stagingDir} 0750 root ${cfg.group} - -"
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
        cfg.sourceDir
        cfg.stagingDir
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = cfg.group;
        UMask = "0027";
        ExecStart = backupCommand;
      };
    };

    host.backups.jobs.${cfg.backupJob}.preparations.jellyfin-built-in-backup = {
      service = "jellyfin-built-in-backup";
      title = "Jellyfin Built-In Backup";
      paths = [ cfg.stagingDir ];
    };
  };
}
