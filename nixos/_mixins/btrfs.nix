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

  actualBtrfsFileSystems = lib.filterAttrs (
    _: fileSystem: fileSystem.fsType == "btrfs"
  ) config.fileSystems;
  actualBtrfsDevices = lib.unique (
    map (fileSystem: fileSystem.device) (builtins.attrValues actualBtrfsFileSystems)
  );
  inventoryBtrfsVolumes = lib.filterAttrs (
    _: volume: volume.fsType == "btrfs"
  ) config.host.storage.volumes;
  inventoryBtrfsDevices = lib.unique (
    map (volume: volume.device) (builtins.attrValues inventoryBtrfsVolumes)
  );
  inventoryBtrfsMounts = builtins.concatLists (
    lib.mapAttrsToList (
      _: volume:
      lib.mapAttrsToList (
        _: mount:
        mount
        // {
          inherit (volume) device fsType;
        }
      ) volume.mounts
    ) inventoryBtrfsVolumes
  );
  snapshotMounts = builtins.filter (mount: mount.snapshots) inventoryBtrfsMounts;

  maintenanceCommand =
    command: arguments:
    utils.escapeSystemdExecArgs (
      [
        maintenance
        command
        "--btrfs"
        btrfs
      ]
      ++ arguments
    );
  scrubCommand =
    command: fileSystem:
    maintenanceCommand command [
      "--mount"
      fileSystem
    ];
  snapshotDirectory =
    mount: if mount.mountPoint == "/" then "/.snapshots" else "${mount.mountPoint}/.snapshots";
  ensureSnapshotsCommand =
    mount:
    maintenanceCommand "ensure-subvolume" [
      "--path"
      (snapshotDirectory mount)
      "--mode"
      "0750"
    ];

  scrubUnitName = fileSystem: "btrfs-scrub-${utils.escapeSystemdPath fileSystem}";
  resumeUnitName = fileSystem: "btrfs-scrub-resume-${utils.escapeSystemdPath fileSystem}";
  mountUnitName = fileSystem: "${utils.escapeSystemdPath fileSystem}.mount";
  snapshotConfigName =
    mount:
    let
      escapedMount = utils.escapeSystemdPath mount.mountPoint;
    in
    if escapedMount == "-" then "root" else escapedMount;
  snapshotsUnitName = mount: "${snapshotConfigName mount}-snapshots-dir";

  scrubService =
    fileSystem:
    lib.nameValuePair (scrubUnitName fileSystem) {
      after = [ (mountUnitName fileSystem) ];
      requires = [ (mountUnitName fileSystem) ];
      serviceConfig.ExecStart = lib.mkForce (scrubCommand "scrub-start-or-resume" fileSystem);
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
        ExecStart = scrubCommand "scrub-resume-if-interrupted" fileSystem;
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
  snapperConfig =
    mount:
    lib.nameValuePair (snapshotConfigName mount) {
      SUBVOLUME = mount.mountPoint;
      TIMELINE_CREATE = true;
      TIMELINE_CLEANUP = true;
      TIMELINE_LIMIT_HOURLY = "0";
      TIMELINE_LIMIT_DAILY = "7";
      TIMELINE_LIMIT_WEEKLY = "4";
      TIMELINE_LIMIT_MONTHLY = "6";
      TIMELINE_LIMIT_YEARLY = "1";
    };
  snapshotsService =
    mount:
    let
      unitName = snapshotsUnitName mount;
      mountUnit = mountUnitName mount.mountPoint;
    in
    lib.nameValuePair unitName {
      description = "Ensure ${snapshotDirectory mount} exists";
      wantedBy = [ "multi-user.target" ];
      after = [ mountUnit ];
      requires = [ mountUnit ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = ensureSnapshotsCommand mount;
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
    {
      assertions = [
        {
          assertion =
            lib.sort builtins.lessThan actualBtrfsDevices == lib.sort builtins.lessThan inventoryBtrfsDevices;
          message = "Inventory Btrfs devices must match the Btrfs devices declared in fileSystems.";
        }
      ]
      ++ map (
        mount:
        let
          actualFileSystem = config.fileSystems.${mount.mountPoint} or null;
        in
        {
          assertion =
            actualFileSystem != null
            && actualFileSystem.device == mount.device
            && actualFileSystem.fsType == mount.fsType;
          message = "Inventory Btrfs mount ${mount.mountPoint} must match its fileSystems declaration.";
        }
      ) inventoryBtrfsMounts;
    }
    (lib.mkIf (actualBtrfsFileSystems != { }) {
      services.btrfs.autoScrub = {
        enable = true;
        resumeInterrupted.enable = true;
      };
    })
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
    (lib.mkIf (snapshotMounts != [ ]) {
      services.snapper.configs = builtins.listToAttrs (map snapperConfig snapshotMounts);
      systemd.services = builtins.listToAttrs (map snapshotsService snapshotMounts) // {
        snapper-timeline = {
          after = map (mount: "${snapshotsUnitName mount}.service") snapshotMounts;
          requires = map (mount: "${snapshotsUnitName mount}.service") snapshotMounts;
        };
      };
    })
  ];
}
