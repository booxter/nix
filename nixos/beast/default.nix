{
  config,
  lib,
  pkgs,
  ...
}:
let
  nfsSubnet = "192.168.0.0/16";
  # Pin export IDs so clients see stable export identities across server restarts.
  mkNfsExport =
    { path, fsid }: "${path} ${nfsSubnet}(rw,async,no_subtree_check,fsid=${toString fsid})";
  nfsPorts = [
    2049 # nfsd
  ];
in
{
  imports = [
    (import ../../disko { })
    ./jellarr.nix
  ];

  # Pin this host to the latest stable release channel (critical infra).
  users.users.ihrachyshka.hashedPassword = "$6$gQ7Gm5b2aq7qPn7W$dcuDT19.SJ88xPA4tQHbscdJDMo3wK.UXGhffrohh7YU4QAzcmRk3GKPNku.BnGrkgDYvZXm/4tBfT.NP6eF.1";

  # Use the freshest kernel available on the stable channel.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Host critical services; keep upgrades on Monday, separate from the
  # fleet's default Saturday schedule.
  system.autoUpgrade.dates = "Mon 03:00";

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
      "x-systemd.device-timeout=5min"
      "x-systemd.mount-timeout=5min"
    ];
  };

  # IPMI quirks (beast):
  # - If BMC gets into a broken state, run: sudo ipmitool raw 0x32 0x66
  # - On first setup, use a simple password (no special chars) or later logins can fail.

  # NFS exports matching existing clients.
  services.nfs.server = {
    enable = true;
    exports = ''
      ${mkNfsExport {
        path = "/volume2/Media";
        fsid = 10; # media export
      }}
      ${mkNfsExport {
        path = "/volume2/nix-cache";
        fsid = 11; # binary cache export
      }}
    '';
  };
  systemd.services.nfs-server.unitConfig.RequiresMountsFor = [
    "/volume2"
    "/volume2/Media"
    "/volume2/nix-cache"
  ];

  services.nfs.settings = {
    nfsd = {
      vers3 = "n";
      vers4 = "y";
    };
  };

  services.rpcbind.enable = lib.mkForce false;

  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };
  users.users.jellyfin.extraGroups = [
    "render"
    "video"
  ];
  systemd.services.jellyfin.unitConfig.RequiresMountsFor = "/media";

  # Reverse proxy with automatic TLS.
  security.acme = {
    acceptTerms = true;
    defaults.email = "ihar.hrachyshka@gmail.com";
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    virtualHosts = {
      "au.ihar.dev" = {
        forceSSL = true;
        enableACME = true;
        locations."/" = {
          # Use fixed VM IP to avoid boot-time DNS dependency.
          proxyPass = "http://192.168.20.2:9292";
          proxyWebsockets = true;
        };
      };
      "jf.ihar.dev" = {
        forceSSL = true;
        enableACME = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:8096";
          proxyWebsockets = true;
        };
      };
      "js.ihar.dev" = {
        forceSSL = true;
        enableACME = true;
        locations."/" = {
          # Use fixed VM IP to avoid boot-time DNS dependency.
          proxyPass = "http://192.168.20.2:5055";
          proxyWebsockets = true;
        };
      };
    };
  };

  # Keep the existing /media path expected by Jellyfin/Jellarr.
  fileSystems."/media" = {
    device = "/volume2/Media";
    fsType = "none";
    options = [
      "bind"
      "nofail"
      "x-systemd.requires-mounts-for=/volume2"
    ];
  };

  networking.firewall.allowedTCPPorts = nfsPorts ++ [
    80
    443
  ];
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

  # Acceleration setup: https://nixos.wiki/wiki/Jellyfin
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-compute-runtime
      vpl-gpu-rt
    ];
  };
}
