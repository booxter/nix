{
  lib,
  utils,
  watchstateModel,
  ...
}:
let
  inherit (watchstateModel)
    backupStagingDirectory
    cfg
    dataDirectory
    tools
    ;
  backup = utils.escapeSystemdExecArgs [
    (lib.getExe' tools "watchstate-native-backup")
    "--data-dir"
    dataDirectory
    "--staging-dir"
    backupStagingDirectory
    "--keep"
    "7"
  ];
in
{
  config = lib.mkIf (cfg != null) {
    systemd.tmpfiles.rules = [
      "d ${backupStagingDirectory} 0750 root restic-cloud - -"
    ];

    systemd.services.watchstate-native-backup = {
      description = "Create a native WatchState backup archive";
      restartIfChanged = false;
      stopIfChanged = false;
      requires = [
        "podman-watchstate.service"
        "podman.socket"
      ];
      after = [
        "podman-watchstate.service"
        "podman.socket"
      ];
      unitConfig.RequiresMountsFor = [ backupStagingDirectory ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "restic-cloud";
        UMask = "0027";
        ExecStart = backup;
        TimeoutStartSec = "2h";
      };
    };

    host.backups.sources.watchstate = {
      title = "WatchState";
      preparation = {
        service = "watchstate-native-backup";
        paths = [ backupStagingDirectory ];
      };
    };
  };
}
