{
  config,
  lib,
  pkgs,
  ...
}:
let
  nfsSubnet = "192.168.0.0/16";
  mkNfsExport = path: "${path} ${nfsSubnet}(rw,async,no_subtree_check)";
  nfsPorts = [
    2049 # nfsd
  ];
in
{
  imports = [
    (import ../../disko { })
  ];

  # Pin this host to the latest stable release channel (critical infra).
  users.users.ihrachyshka.hashedPassword = "$6$gQ7Gm5b2aq7qPn7W$dcuDT19.SJ88xPA4tQHbscdJDMo3wK.UXGhffrohh7YU4QAzcmRk3GKPNku.BnGrkgDYvZXm/4tBfT.NP6eF.1";

  # Use the freshest kernel available on the stable channel.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Assemble the existing RAID6 array from the previous NAS.
  # Auto-assembly should work; add explicit mdadm config only if needed.
  boot.swraid.enable = true;
  boot.swraid.mdadmConf = "PROGRAM ${pkgs.util-linux}/bin/logger -t mdadm-monitor";

  boot.supportedFilesystems = [ "btrfs" ];

  # Keep /volume2 for compatibility with existing NFS client paths.
  fileSystems."/volume2" = {
    device = "/dev/disk/by-uuid/6c1ea7bf-4fd8-482a-aa6e-a35129c628e6";
    fsType = "btrfs";
    options = [
      "compress=zstd"
      "noatime"
      "nofail"
      "x-systemd.device-timeout=10s"
    ];
  };

  # IPMI quirks (beast):
  # - If BMC gets into a broken state, run: sudo ipmitool raw 0x32 0x66
  # - On first setup, use a simple password (no special chars) or later logins can fail.

  # NFS exports matching existing clients.
  services.nfs.server = {
    enable = true;
    extraNfsdConfig = ''
      vers3 = n
      vers4 = y
    '';
    exports = ''
      ${mkNfsExport "/volume2/Media"}
      ${mkNfsExport "/volume2/nix-cache"}
    '';
  };

  services.rpcbind.enable = lib.mkForce false;

  networking.firewall.allowedTCPPorts = nfsPorts;
  networking.firewall.allowedUDPPorts = nfsPorts;

  networking.resolvconf.enable = true;

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

  # Regular btrfs scrubs for data integrity.
  services.btrfs.autoScrub = {
    enable = true;
    fileSystems = [ "/volume2" ];
    interval = "monthly";
  };

  # Local disk health monitoring (logs to journal; email relay can be added later).
  services.smartd = {
    enable = true;
    autodetect = true;
  };

  environment.systemPackages = with pkgs; [
    btrfs-progs
    hdparm
    lm_sensors
    mdadm
    nvme-cli
    smartmontools
  ];
}
