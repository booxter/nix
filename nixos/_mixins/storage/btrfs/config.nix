{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.storage.btrfs;
  helpers = import ./lib.nix { inherit lib utils; };
  maintenancePackage = pkgs.callPackage ./package { };
  maintenance = lib.getExe maintenancePackage;
  btrfs = lib.getExe pkgs.btrfs-progs;
  btrfsMounts = helpers.btrfsMounts config.fileSystems;
  scrubMountPoints = map (mount: mount.mountPoint) btrfsMounts;
  snapshots = cfg.snapshots;
  command =
    arguments:
    utils.escapeSystemdExecArgs (
      [ maintenance ]
      ++ arguments
      ++ [
        "--btrfs"
        btrfs
      ]
    );
  scrubCommand =
    operation: mountPoint:
    command [
      operation
      "--mount"
      mountPoint
    ];
  snapshotUnit = mountPoint: "${helpers.snapshotName mountPoint}-snapshots-dir";
  snapshotUnits = map snapshotUnit (builtins.attrNames snapshots);
in
{
  config = lib.mkMerge [
    (lib.mkIf (scrubMountPoints != [ ]) {
      services.btrfs.autoScrub = {
        enable = true;
        fileSystems = scrubMountPoints;
        interval = "monthly";
      };

      systemd.services = lib.mkMerge (
        map (
          mountPoint:
          let
            suffix = helpers.scrubUnitSuffix mountPoint;
          in
          {
            "btrfs-scrub-${suffix}" = {
              after = [ (helpers.mountUnit mountPoint) ];
              requires = [ (helpers.mountUnit mountPoint) ];
              serviceConfig.ExecStart = lib.mkForce (scrubCommand "scrub-start-or-resume" mountPoint);
            };

            "btrfs-scrub-resume-${suffix}" = {
              description = "Resume interrupted Btrfs scrub on ${mountPoint}";
              after = [ (helpers.mountUnit mountPoint) ];
              requires = [ (helpers.mountUnit mountPoint) ];
              serviceConfig = {
                Type = "simple";
                ExecStart = scrubCommand "scrub-resume-if-interrupted" mountPoint;
                IOSchedulingClass = "idle";
                Nice = 19;
              };
            };
          }
        ) scrubMountPoints
      );

      systemd.timers = lib.listToAttrs (
        map (
          mountPoint:
          let
            suffix = helpers.scrubUnitSuffix mountPoint;
          in
          lib.nameValuePair "btrfs-scrub-resume-${suffix}" {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = "5min";
              Unit = "btrfs-scrub-resume-${suffix}.service";
            };
          }
        ) scrubMountPoints
      );
    })

    (lib.mkIf (snapshots != { }) {
      services.snapper.configs = lib.mapAttrs' (
        mountPoint: snapshot:
        lib.nameValuePair (helpers.snapshotName mountPoint) {
          SUBVOLUME = mountPoint;
          TIMELINE_CREATE = true;
          TIMELINE_CLEANUP = true;
          TIMELINE_LIMIT_HOURLY = toString snapshot.retention.hourly;
          TIMELINE_LIMIT_DAILY = toString snapshot.retention.daily;
          TIMELINE_LIMIT_WEEKLY = toString snapshot.retention.weekly;
          TIMELINE_LIMIT_MONTHLY = toString snapshot.retention.monthly;
          TIMELINE_LIMIT_YEARLY = toString snapshot.retention.yearly;
        }
      ) snapshots;

      systemd.services = lib.mkMerge [
        (lib.mapAttrs' (
          mountPoint: _:
          let
            unit = snapshotUnit mountPoint;
            mount = helpers.mountUnit mountPoint;
          in
          lib.nameValuePair unit {
            description = "Ensure ${helpers.snapshotsPath mountPoint} exists";
            wantedBy = [ "multi-user.target" ];
            after = [ mount ];
            requires = [ mount ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = command [
                "ensure-subvolume"
                "--path"
                (helpers.snapshotsPath mountPoint)
                "--mode"
                "0750"
              ];
            };
          }
        ) snapshots)
        {
          snapper-timeline = {
            after = map (unit: "${unit}.service") snapshotUnits;
            requires = map (unit: "${unit}.service") snapshotUnits;
          };
        }
      ];
    })
  ];
}
