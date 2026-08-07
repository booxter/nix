{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.btrfs.autoScrub;
  resumeCfg = cfg.resumeInterrupted;
  maintenancePackage = pkgs.callPackage ./backups/server/pkgs/backup-server-tools { };
  maintenance = lib.getExe' maintenancePackage "btrfs-maintenance";
  btrfs = lib.getExe pkgs.btrfs-progs;
  maintenanceCommand =
    command: fileSystem:
    utils.escapeSystemdExecArgs [
      maintenance
      command
      "--btrfs"
      btrfs
      "--mount"
      fileSystem
    ];
  scrubUnitName = fileSystem: "btrfs-scrub-${utils.escapeSystemdPath fileSystem}";
  resumeUnitName = fileSystem: "btrfs-scrub-resume-${utils.escapeSystemdPath fileSystem}";
  mountUnitName = fileSystem: "${utils.escapeSystemdPath fileSystem}.mount";
  scrubService =
    fileSystem:
    lib.nameValuePair (scrubUnitName fileSystem) {
      after = [ (mountUnitName fileSystem) ];
      requires = [ (mountUnitName fileSystem) ];
      serviceConfig.ExecStart = lib.mkForce (maintenanceCommand "scrub-start-or-resume" fileSystem);
    };
  resumeService =
    fileSystem:
    lib.nameValuePair (resumeUnitName fileSystem) {
      description = "Resume interrupted btrfs scrub on ${fileSystem}";
      after = [ (mountUnitName fileSystem) ];
      before = [
        "shutdown.target"
        "sleep.target"
      ];
      conflicts = [
        "shutdown.target"
        "sleep.target"
      ];
      requires = [ (mountUnitName fileSystem) ];
      serviceConfig = {
        Type = "simple";
        ExecStart = maintenanceCommand "scrub-resume-if-interrupted" fileSystem;
        IOSchedulingClass = "idle";
        Nice = 19;
      };
    };
  resumeTimer =
    fileSystem:
    let
      unitName = resumeUnitName fileSystem;
    in
    lib.nameValuePair unitName {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = resumeCfg.onBootSec;
        Unit = "${unitName}.service";
      };
    };
in
{
  options.services.btrfs.autoScrub.resumeInterrupted = {
    enable = lib.mkEnableOption "resuming interrupted btrfs scrubs";

    onBootSec = lib.mkOption {
      type = lib.types.str;
      default = "5min";
      description = "Delay after boot before attempting to resume interrupted scrubs.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf resumeCfg.enable {
      assertions = [
        {
          assertion = cfg.enable;
          message = "services.btrfs.autoScrub.resumeInterrupted requires autoScrub.enable.";
        }
      ];
    })
    (lib.mkIf (cfg.enable && resumeCfg.enable) {
      systemd.services = builtins.listToAttrs (
        map scrubService cfg.fileSystems ++ map resumeService cfg.fileSystems
      );
      systemd.timers = builtins.listToAttrs (map resumeTimer cfg.fileSystems);
    })
  ];
}
