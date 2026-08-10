{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.watchstate;
  atomicFileWrites = pkgs.python3Packages.callPackage ../../../pkgs/atomic-file-writes { };
  tools = pkgs.callPackage ./packages/tools { inherit atomicFileWrites; };
  backup = utils.escapeSystemdExecArgs [
    (lib.getExe' tools "watchstate-native-backup")
    "--data-dir"
    cfg.dataDirectory
    "--staging-dir"
    cfg.backups.stagingDirectory
    "--keep"
    "7"
  ];
in
{
  config = lib.mkIf (cfg.enable && cfg.backups.enable) {
    systemd.tmpfiles.rules = [
      "d ${cfg.backups.stagingDirectory} 0750 root restic-cloud - -"
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
      unitConfig.RequiresMountsFor = [ cfg.backups.stagingDirectory ];
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
      capture = {
        type = "unit";
        unit = {
          service = "watchstate-native-backup";
          outputPaths = [ cfg.backups.stagingDirectory ];
        };
      };
    };
  };
}
