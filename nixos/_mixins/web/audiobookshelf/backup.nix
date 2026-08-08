{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.audiobookshelf;
  backupCfg = cfg.nativeBackup;
  settingsFile = (pkgs.formats.json { }).generate "audiobookshelf-backup-settings.json" {
    backupSchedule = backupCfg.schedule;
    backupsToKeep = backupCfg.keep;
    maxBackupSize = backupCfg.maxSizeGiB;
  };
  bootstrapCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' cfg.tools.package "audiobookshelf-backup-bootstrap")
    "--url"
    cfg.localUrl
    "--credential-name"
    "api-token"
    "--settings-file"
    settingsFile
  ];
in
{
  options.services.audiobookshelf.nativeBackup = {
    enable = lib.mkEnableOption "Audiobookshelf native backups";

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "15 4 * * *";
      description = "Cron schedule configured for Audiobookshelf native backups.";
    };

    keep = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 2;
      description = "Number of native Audiobookshelf backups to retain; zero is unlimited.";
    };

    maxSizeGiB = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1;
      description = "Maximum native Audiobookshelf backup size in GiB; zero is unlimited.";
    };

    backupJob = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Host backup job that includes Audiobookshelf native archives.";
    };

    path = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.metadataDir}/backups";
      description = "Directory containing Audiobookshelf native backup archives.";
    };
  };

  config = lib.mkIf backupCfg.enable {
    assertions = [
      {
        assertion = cfg.enable;
        message = "services.audiobookshelf.nativeBackup requires services.audiobookshelf.enable.";
      }
      {
        assertion = backupCfg.backupJob != "";
        message = "services.audiobookshelf.nativeBackup.backupJob must be set.";
      }
    ];

    systemd.services.audiobookshelf-backup-bootstrap = {
      description = "Enable Audiobookshelf native backups";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "audiobookshelf.service"
        "sops-install-secrets.service"
      ];
      after = [
        "audiobookshelf.service"
        "sops-install-secrets.service"
      ];
      unitConfig.RequiresMountsFor = [ cfg.stateDir ];
      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        LoadCredential = "api-token:${cfg.apiToken.file}";
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ExecStart = bootstrapCommand;
      };
    };

    systemd.services.audiobookshelf.environment.BACKUP_PATH = backupCfg.path;

    systemd.tmpfiles.rules = [
      "d '${backupCfg.path}' 0700 ${cfg.user} ${cfg.group} - -"
    ];

    host.backups.jobs.${backupCfg.backupJob}.paths = [ backupCfg.path ];
  };
}
