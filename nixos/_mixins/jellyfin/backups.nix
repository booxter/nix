{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.jellyfin;
  tools = pkgs.callPackage ./packages/tools { };
  sourceDirectory = "/var/lib/jellyfin/data/backups";
  backupCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' tools "jellyfin-built-in-backup")
    "--url"
    cfg.localUrl
    "--api-key-file"
    cfg.apiKeyFile
    "--source-dir"
    sourceDirectory
    "--staging-dir"
    cfg.backups.stagingDirectory
    "--keep-staging"
    "7"
    "--keep-source"
    "1"
  ];
in
{
  config = lib.mkIf (cfg.enable && cfg.backups.enable) {
    systemd.tmpfiles.rules = [
      "d ${cfg.backups.stagingDirectory} 0750 root restic-cloud - -"
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
        sourceDirectory
        cfg.backups.stagingDirectory
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "restic-cloud";
        UMask = "0027";
        ExecStart = backupCommand;
      };
    };

    host.backups.sources.jellyfin = {
      title = "Jellyfin";
      capture = {
        type = "unit";
        unit = {
          service = "jellyfin-built-in-backup";
          outputPaths = [ cfg.backups.stagingDirectory ];
        };
      };
    };
  };
}
