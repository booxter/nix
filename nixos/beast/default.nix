{
  config,
  lib,
  pkgs,
  ...
}:
let
  nfsSubnet = "192.168.0.0/16";
  smartctlExporterPort = 9633;
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";
  # Pin export IDs so clients see stable export identities across server restarts.
  mkNfsExport =
    { path, fsid }: "${path} ${nfsSubnet}(rw,async,no_subtree_check,fsid=${toString fsid})";
  mkDisablePauseService = iface: {
    description = "Disable Ethernet pause frames on ${iface}";
    after = [ "network-pre.target" ];
    wants = [ "network-pre.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.ethtool}/bin/ethtool -A ${iface} autoneg off rx off tx off";
      RemainAfterExit = true;
    };
  };
  nfsPorts = [
    2049 # nfsd
  ];
  # DDNS provider target for public endpoints (jf/au/js).
  dynuHostname = "ihrachyshka-home.freeddns.org";
  dynuUsername = "ihrachyshka";
  diskBayMappings = [
    {
      bay = "1";
      serial = "ZYD01W48";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "3";
      serial = "ZYD0CASB";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "5";
      serial = "ZYD05Z4J";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "6";
      serial = "ZYD041CP";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "7";
      serial = "ZXA0RKFF";
      model = "ST24000NM000C-3WD103";
    }
    {
      bay = "9";
      serial = "ZXA0B5K4";
      model = "ST24000NM000C-3WD103";
    }
    {
      bay = "10";
      serial = "ZXA0FFNN";
      model = "ST24000NM000C-3WD103";
    }
    {
      bay = "11";
      serial = "ZYD01W92";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "13";
      serial = "ZYD02EQQ";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "15";
      serial = "ZXA0GW38";
      model = "ST24000NM000C-3WD103";
    }
  ];
  diskBayExporter = pkgs.writeShellScript "beast-disk-bay-export" ''
    set -euo pipefail

    mkdir -p ${textfileDir}
    tmp_file="$(mktemp ${textfileDir}/disk-bays.prom.XXXXXX)"
    trap 'rm -f "$tmp_file"' EXIT

    cat > "$tmp_file" <<'EOF'
    # HELP host_observability_disk_bay_info Current mapping of beast disk device names to physical bays.
    # TYPE host_observability_disk_bay_info gauge
    EOF

    ${lib.concatMapStringsSep "\n" (mapping: ''
      device="$(${pkgs.util-linux}/bin/lsblk -dn -o NAME,SERIAL | ${pkgs.gawk}/bin/awk '$2 == "${mapping.serial}" { print $1; exit }')"
      if [ -n "$device" ]; then
        printf 'host_observability_disk_bay_info{device="%s",bay="${mapping.bay}",serial="${mapping.serial}",model="${mapping.model}"} 1\n' "$device" >> "$tmp_file"
      fi
    '') diskBayMappings}

    chmod 0644 "$tmp_file"
    mv "$tmp_file" ${textfileDir}/disk-bays.prom
    trap - EXIT
  '';
in
{
  imports = [
    (import ../../disko { })
    ./backup-server.nix
    ./jellyfin-backup.nix
    ./jellarr.nix
  ];

  # Pin this host to the latest stable release channel (critical infra).
  users.users.ihrachyshka.hashedPassword = "$6$gQ7Gm5b2aq7qPn7W$dcuDT19.SJ88xPA4tQHbscdJDMo3wK.UXGhffrohh7YU4QAzcmRk3GKPNku.BnGrkgDYvZXm/4tBfT.NP6eF.1";

  # Use the freshest kernel available on the stable channel.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Host critical services; keep upgrades on Monday, separate from the fleet's
  # default Saturday schedule, but still leave room for local backups and later
  # cloud offload jobs after the reboot window work settles.
  system.autoUpgrade.dates = "Mon 03:30";
  system.autoUpgrade.randomizedDelaySec = "15min";

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

  # fwupd startup times out probing a Nordic USB receiver on /dev/hidraw0
  # (VID:PID 1915:1025) via the nordic_hid plugin.
  services.fwupd.daemonSettings.DisabledPlugins = [ "nordic_hid" ];

  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };
  users.users.jellyfin.extraGroups = [
    "render"
    "video"
  ];
  users.groups.ddclient-secrets = { };
  systemd.services.jellyfin.unitConfig.RequiresMountsFor = "/media";

  # Reverse proxy with automatic TLS.
  security.acme = {
    acceptTerms = true;
    defaults.email = "ihar.hrachyshka@gmail.com";
  };

  # Run DDNS updates from this host (instead of the router).
  sops = {
    defaultSopsFile = ../../secrets/beast.yaml;
    useSystemdActivation = true;
    secrets.ddnsDynuPassword = {
      key = "ddns/dynu/password";
      group = "ddclient-secrets";
      mode = "0440";
    };
  };

  services.ddclient = {
    enable = true;
    interval = "1min";
    protocol = "dyndns2";
    server = "api.dynu.com";
    username = dynuUsername;
    passwordFile = config.sops.secrets.ddnsDynuPassword.path;
    domains = [ dynuHostname ];
    ssl = true;
    quiet = true;
    usev4 = "webv4,webv4=checkip.dynu.com/,webv4-skip='IP Address'";
    usev6 = "";
  };
  systemd.services.ddclient = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
    serviceConfig = {
      SupplementaryGroups = [ "ddclient-secrets" ];
    };
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
    smartctlExporterPort
  ];
  networking.firewall.allowedUDPPorts = nfsPorts;

  networking.resolvconf.enable = true;

  # Link on TL2-F7120 can drop intermittently; disabling pause frames here
  # has helped stability. Flow control is also disabled on the switch port.
  systemd.services.ethtool-enp10s0-disable-pause = mkDisablePauseService "enp10s0";
  systemd.services.ethtool-enp11s0-disable-pause = mkDisablePauseService "enp11s0";

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

  services.prometheus.exporters.smartctl = {
    enable = true;
    port = smartctlExporterPort;
    listenAddress = "0.0.0.0";
    openFirewall = false;
    extraFlags = [
      "--smartctl.path=${pkgs.smartmontools}/bin/smartctl"
      "--smartctl.device-include=^(sd[a-z]+)$"
    ];
  };

  services.prometheus.exporters.node = {
    enabledCollectors = lib.mkForce [
      "processes"
      "systemd"
      "textfile"
    ];
    extraFlags = lib.mkForce [ "--collector.textfile.directory=${textfileDir}" ];
  };

  systemd.services.beast-disk-bay-export = {
    description = "Export beast disk bay mapping for node exporter";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = diskBayExporter;
    };
  };

  systemd.tmpfiles.rules = [
    "d ${textfileDir} 0755 root root - -"
  ];

  environment.systemPackages = with pkgs; [
    btrfs-progs
    hdparm
    intel-gpu-tools
    libva-utils
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
