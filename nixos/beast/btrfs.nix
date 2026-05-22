{ pkgs, ... }:
{
  boot.supportedFilesystems = [ "btrfs" ];

  # Keep /volume2 for compatibility with existing NFS client paths.
  fileSystems."/volume2" = {
    device = "/dev/disk/by-uuid/6c1ea7bf-4fd8-482a-aa6e-a35129c628e6";
    fsType = "btrfs";
    options = [
      "compress=zstd"
      "noatime"
      "nofail"
      "x-systemd.device-timeout=5min"
      "x-systemd.mount-timeout=5min"
    ];
  };

  # Snapshot schedule for /volume2. This creates /volume2/.snapshots.
  services.snapper.configs.volume2 = {
    SUBVOLUME = "/volume2";
    TIMELINE_CREATE = true;
    TIMELINE_CLEANUP = true;
    TIMELINE_LIMIT_HOURLY = "0";
    TIMELINE_LIMIT_DAILY = "7";
    TIMELINE_LIMIT_WEEKLY = "4";
    TIMELINE_LIMIT_MONTHLY = "6";
    TIMELINE_LIMIT_YEARLY = "1";
  };

  systemd.services.volume2-snapshots-dir = {
    description = "Ensure /volume2/.snapshots exists";
    wantedBy = [ "multi-user.target" ];
    after = [ "volume2.mount" ];
    requires = [ "volume2.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.btrfs-progs}/bin/btrfs subvolume show /volume2/.snapshots >/dev/null 2>&1 || ${pkgs.btrfs-progs}/bin/btrfs subvolume create /volume2/.snapshots'";
      ExecStartPost = "${pkgs.coreutils}/bin/chmod 0750 /volume2/.snapshots";
    };
  };

  systemd.services.snapper-timeline = {
    after = [ "volume2-snapshots-dir.service" ];
    requires = [ "volume2-snapshots-dir.service" ];
  };

  # Regular btrfs scrubs for data integrity.
  services.btrfs.autoScrub = {
    enable = true;
    fileSystems = [ "/volume2" ];
    interval = "monthly";
  };
  systemd.services."btrfs-scrub-volume2" = {
    after = [ "volume2.mount" ];
    requires = [ "volume2.mount" ];
  };

  environment.systemPackages = [
    pkgs.btrfs-progs
  ];
}
