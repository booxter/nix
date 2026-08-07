{
  beastPkgs,
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  dataVolume = config.host.storage.volumes.data;
  volume2 = dataVolume.mountPoint;
  volume2MountUnit = "${utils.escapeSystemdPath volume2}.mount";
  maintenance = lib.getExe' beastPkgs.backup-server-tools "btrfs-maintenance";
  btrfs = lib.getExe pkgs.btrfs-progs;
  maintenanceCommand =
    command: extraArguments:
    utils.escapeSystemdExecArgs (
      [
        maintenance
        command
        "--btrfs"
        btrfs
      ]
      ++ extraArguments
    );
  ensureSnapshots = maintenanceCommand "ensure-subvolume" [
    "--path"
    "${volume2}/.snapshots"
    "--mode"
    "0750"
  ];
in
{
  imports = [ ../_mixins/btrfs-scrub.nix ];

  # Keep the existing mount point for compatibility with storage consumers.
  fileSystems.${volume2} = {
    inherit (dataVolume) device fsType;
    options = [
      "compress=zstd"
      "noatime"
      "nofail"
      "x-systemd.device-timeout=5min"
      "x-systemd.mount-timeout=15min"
    ];
  };

  # Snapshot schedule for the data volume.
  services.snapper.configs.volume2 = {
    SUBVOLUME = volume2;
    TIMELINE_CREATE = true;
    TIMELINE_CLEANUP = true;
    TIMELINE_LIMIT_HOURLY = "0";
    TIMELINE_LIMIT_DAILY = "7";
    TIMELINE_LIMIT_WEEKLY = "4";
    TIMELINE_LIMIT_MONTHLY = "6";
    TIMELINE_LIMIT_YEARLY = "1";
  };

  systemd.services.volume2-snapshots-dir = {
    description = "Ensure ${volume2}/.snapshots exists";
    wantedBy = [ "multi-user.target" ];
    after = [ volume2MountUnit ];
    requires = [ volume2MountUnit ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = ensureSnapshots;
    };
  };

  systemd.services.snapper-timeline = {
    after = [ "volume2-snapshots-dir.service" ];
    requires = [ "volume2-snapshots-dir.service" ];
  };

  # Regular btrfs scrubs for data integrity.
  services.btrfs.autoScrub = {
    enable = true;
    fileSystems = [ volume2 ];
    interval = "monthly";
    resumeInterrupted = {
      enable = true;
      onBootSec = "5min";
    };
  };
}
