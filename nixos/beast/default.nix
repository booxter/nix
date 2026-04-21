{
  config,
  lib,
  pkgs,
  ...
}:
let
  mediaLibraries = import ./media-libraries.nix;
  mediaPaths = import ./media-paths.nix;
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
  mkPublicProxyVhost = proxyPass: {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = proxyPass;
      proxyWebsockets = true;
    };
  };
  diskBayMappings = [
    {
      bay = "1";
      row = "1";
      col = "1";
      serial = "ZYD01W48";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "3";
      row = "3";
      col = "1";
      serial = "ZYD0CASB";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "5";
      row = "5";
      col = "1";
      serial = "ZYD05Z4J";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "6";
      row = "1";
      col = "2";
      serial = "ZYD041CP";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "7";
      row = "2";
      col = "2";
      serial = "ZXA0RKFF";
      model = "ST24000NM000C-3WD103";
    }
    {
      bay = "9";
      row = "4";
      col = "2";
      serial = "ZXA0B5K4";
      model = "ST24000NM000C-3WD103";
    }
    {
      bay = "10";
      row = "5";
      col = "2";
      serial = "ZXA0FFNN";
      model = "ST24000NM000C-3WD103";
    }
    {
      bay = "11";
      row = "1";
      col = "3";
      serial = "ZYD01W92";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "12";
      row = "2";
      col = "3";
      serial = "ZXA0GW38";
      model = "ST24000NM000C-3WD103";
    }
    {
      bay = "13";
      row = "3";
      col = "3";
      serial = "ZYD02EQQ";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "15";
      row = "5";
      col = "3";
      serial = "ZXA0ENE4";
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
        printf 'host_observability_disk_bay_info{device="%s",bay="${mapping.bay}",bay_row="${mapping.row}",bay_col="${mapping.col}",serial="${mapping.serial}",model="${mapping.model}"} 1\n' "$device" >> "$tmp_file"
      fi
    '') diskBayMappings}

    chmod 0644 "$tmp_file"
    mv "$tmp_file" ${textfileDir}/disk-bays.prom
    trap - EXIT
  '';
  mdSyncExporter = pkgs.writeShellScript "beast-md-sync-export" ''
    set -euo pipefail

    mkdir -p ${textfileDir}
    tmp_file="$(${pkgs.coreutils}/bin/mktemp ${textfileDir}/md-sync.prom.XXXXXX)"
    trap 'rm -f "$tmp_file"' EXIT

    cat > "$tmp_file" <<'EOF'
    # HELP host_observability_md_sync_action_info Current md background action for the array.
    # TYPE host_observability_md_sync_action_info gauge
    # HELP host_observability_md_sync_active Whether the md array currently has background work active.
    # TYPE host_observability_md_sync_active gauge
    # HELP host_observability_md_sync_progress_percent Current md background work completion percentage.
    # TYPE host_observability_md_sync_progress_percent gauge
    # HELP host_observability_md_sync_completed_sectors Current md background work completed sectors.
    # TYPE host_observability_md_sync_completed_sectors gauge
    # HELP host_observability_md_sync_total_sectors Current md background work total sectors.
    # TYPE host_observability_md_sync_total_sectors gauge
    # HELP host_observability_md_sync_speed_bytes_per_second Estimated md background work speed in bytes per second.
    # TYPE host_observability_md_sync_speed_bytes_per_second gauge
    # HELP host_observability_md_sync_eta_seconds Estimated md background work remaining time in seconds.
    # TYPE host_observability_md_sync_eta_seconds gauge
    # HELP host_observability_md_raid_disks Current and previous md raid disk counts during reshape.
    # TYPE host_observability_md_raid_disks gauge
    # HELP host_observability_md_degraded Current md degraded member count.
    # TYPE host_observability_md_degraded gauge
    EOF

    shopt -s nullglob
    for md_dir in /sys/block/md*/md; do
      device="''${md_dir#/sys/block/}"
      device="''${device%/md}"

      action="$(< "$md_dir/sync_action")"
      action="''${action//$'\n'/}"
      case "$action" in
        idle) action_title="Idle" ;;
        reshape) action_title="Reshape" ;;
        recover) action_title="Recover" ;;
        recovering) action_title="Recovering" ;;
        resync) action_title="Resync" ;;
        check) action_title="Check" ;;
        repair) action_title="Repair" ;;
        frozen) action_title="Frozen" ;;
        *) action_title="$action" ;;
      esac

      active=0
      if [ "$action" != "idle" ]; then
        active=1
      fi

      degraded=0
      if [ -r "$md_dir/degraded" ]; then
        degraded="$(< "$md_dir/degraded")"
        degraded="''${degraded//$'\n'/}"
      fi

      completed_sectors=0
      total_sectors=0
      progress_percent=0
      if [ -r "$md_dir/sync_completed" ]; then
        sync_completed="$(< "$md_dir/sync_completed")"
        if printf '%s\n' "$sync_completed" | ${pkgs.gnugrep}/bin/grep -q '/'; then
          completed_sectors="$(printf '%s\n' "$sync_completed" | ${pkgs.gawk}/bin/awk '{print $1}')"
          total_sectors="$(printf '%s\n' "$sync_completed" | ${pkgs.gawk}/bin/awk '{print $3}')"
          if [ "$total_sectors" -gt 0 ]; then
            progress_percent="$(${pkgs.gawk}/bin/awk -v completed="$completed_sectors" -v total="$total_sectors" 'BEGIN { printf "%.6f", (100 * completed) / total }')"
          fi
        fi
      fi

      speed_kib_per_second=0
      speed_bytes_per_second=0
      if [ -r "$md_dir/sync_speed" ]; then
        speed_kib_per_second="$(${pkgs.gawk}/bin/awk '{print $1}' "$md_dir/sync_speed")"
        speed_bytes_per_second="$(${pkgs.gawk}/bin/awk -v speed_kib="$speed_kib_per_second" 'BEGIN { printf "%.0f", speed_kib * 1024 }')"
      fi

      eta_seconds=0
      if [ "$active" -eq 1 ] && [ "$speed_kib_per_second" -gt 0 ] && [ "$total_sectors" -gt "$completed_sectors" ]; then
        remaining_sectors=$((total_sectors - completed_sectors))
        eta_seconds="$(${pkgs.gawk}/bin/awk -v remaining="$remaining_sectors" -v speed_kib="$speed_kib_per_second" 'BEGIN { printf "%.0f", remaining / (2 * speed_kib) }')"
      fi

      raid_disks_raw="$(< "$md_dir/raid_disks")"
      raid_disks_current="$(printf '%s\n' "$raid_disks_raw" | ${pkgs.gawk}/bin/awk '{print $1}')"
      raid_disks_previous="$(printf '%s\n' "$raid_disks_raw" | ${pkgs.gnused}/bin/sed -n 's/.*(\([0-9][0-9]*\)).*/\1/p')"
      if [ -z "$raid_disks_previous" ]; then
        raid_disks_previous="$raid_disks_current"
      fi

      printf 'host_observability_md_sync_action_info{device="%s",action="%s",action_title="%s"} 1\n' \
        "$device" "$action" "$action_title" >> "$tmp_file"
      printf 'host_observability_md_sync_active{device="%s",action="%s"} %s\n' \
        "$device" "$action" "$active" >> "$tmp_file"
      printf 'host_observability_md_sync_progress_percent{device="%s",action="%s"} %s\n' \
        "$device" "$action" "$progress_percent" >> "$tmp_file"
      printf 'host_observability_md_sync_completed_sectors{device="%s",action="%s"} %s\n' \
        "$device" "$action" "$completed_sectors" >> "$tmp_file"
      printf 'host_observability_md_sync_total_sectors{device="%s",action="%s"} %s\n' \
        "$device" "$action" "$total_sectors" >> "$tmp_file"
      printf 'host_observability_md_sync_speed_bytes_per_second{device="%s",action="%s"} %s\n' \
        "$device" "$action" "$speed_bytes_per_second" >> "$tmp_file"
      printf 'host_observability_md_sync_eta_seconds{device="%s",action="%s"} %s\n' \
        "$device" "$action" "$eta_seconds" >> "$tmp_file"
      printf 'host_observability_md_raid_disks{device="%s",phase="current"} %s\n' \
        "$device" "$raid_disks_current" >> "$tmp_file"
      printf 'host_observability_md_raid_disks{device="%s",phase="previous"} %s\n' \
        "$device" "$raid_disks_previous" >> "$tmp_file"
      printf 'host_observability_md_degraded{device="%s"} %s\n' \
        "$device" "$degraded" >> "$tmp_file"
    done

    chmod 0644 "$tmp_file"
    mv "$tmp_file" ${textfileDir}/md-sync.prom
    trap - EXIT
  '';
in
{
  imports = [
    (import ../../disko { })
    ./backup-server.nix
    ./jellyfin-backup.nix
    ./jellarr.nix
    ./ups.nix
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

  # Temporary RAID maintenance boot profile. Keep storage down on boot so the
  # interrupted reshape can be inspected and recovered manually after a cold
  # power cycle.
  boot.swraid.enable = lib.mkForce false;
  boot.swraid.mdadmConf = "PROGRAM ${pkgs.util-linux}/bin/logger -t mdadm-monitor";
  # Keep md reshape/recovery background I/O gentle so media serving stays responsive.
  boot.kernel.sysctl."dev.raid.speed_limit_max" = 20000;

  boot.supportedFilesystems = [ "btrfs" ];

  # Keep /volume2 for compatibility with existing NFS client paths.
  fileSystems."/volume2" = {
    device = "/dev/disk/by-uuid/6c1ea7bf-4fd8-482a-aa6e-a35129c628e6";
    fsType = "btrfs";
    options = [
      "ro"
      "noauto"
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
    enable = lib.mkForce false;
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
    enable = lib.mkForce false;
    openFirewall = true;
  };
  users.groups.media.gid = 169;
  users.users.jellyfin = lib.mkIf config.services.jellyfin.enable {
    extraGroups = [
      "media"
      "render"
      "video"
    ];
  };
  # Keep ddclient on a stable system user instead of DynamicUser. During
  # switch-to-configuration we observed a transient startup failure where the
  # generated preStart script tried to chown runtime files to "ddclient" before
  # the dynamic user/runtime state was ready.
  users.groups = {
    ddclient = { };
    ddclient-secrets = { };
  };
  users.users.ddclient = {
    isSystemUser = true;
    group = "ddclient";
  };
  systemd.services.jellyfin.unitConfig.RequiresMountsFor = lib.mkIf config.services.jellyfin.enable "/media";

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
      DynamicUser = lib.mkForce false;
      User = "ddclient";
      Group = "ddclient";
      SupplementaryGroups = [ "ddclient-secrets" ];
    };
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    virtualHosts = {
      # Use fixed VM IPs to avoid boot-time DNS dependency.
      "au.ihar.dev" = mkPublicProxyVhost "http://192.168.20.2:9292";
      "jf.ihar.dev" = mkPublicProxyVhost "http://127.0.0.1:8096";
      "js.ihar.dev" = mkPublicProxyVhost "http://192.168.20.2:5055";
      "vi.ihar.dev" = mkPublicProxyVhost "http://192.168.20.4:3456";
    };
  };

  # Keep the existing /media path expected by Jellyfin/Jellarr.
  fileSystems."/media" = {
    device = "/volume2/Media";
    fsType = "none";
    options = [
      "bind"
      "ro"
      "noauto"
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

  services.prometheus.exporters.ipmi = {
    enable = true;
    listenAddress = "0.0.0.0";
    openFirewall = true;
    configFile = (pkgs.formats.yaml { }).generate "ipmi-local.yml" {
      modules.default.collectors = [
        "ipmi"
        "chassis"
      ];
    };
  };

  users.users.ipmi-exporter = {
    description = "Prometheus ipmi exporter service user";
    isSystemUser = true;
    group = "ipmi-exporter";
    extraGroups = [ "ipmi-exporter-access" ];
  };

  users.groups.ipmi-exporter = { };
  users.groups.ipmi-exporter-access = { };

  services.udev.extraRules = ''
    KERNEL=="ipmi[0-9]*", SUBSYSTEM=="ipmi", GROUP="ipmi-exporter-access", MODE="0660"
  '';

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

  systemd.services.beast-md-sync-export = {
    description = "Export md sync status for node exporter";
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = mdSyncExporter;
    };
  };

  systemd.timers.beast-md-sync-export = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "1min";
      Unit = "beast-md-sync-export.service";
    };
  };

  systemd.services.prometheus-ipmi-exporter.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = lib.mkForce "ipmi-exporter";
    Group = lib.mkForce "ipmi-exporter";
    SupplementaryGroups = [ "ipmi-exporter-access" ];
    BindPaths = [ "/dev/ipmi0" ];
    DeviceAllow = [ "/dev/ipmi0 rw" ];
  };

  systemd.tmpfiles.rules = [
    "d ${textfileDir} 0755 root root - -"
  ]
  ++ lib.concatMap (library: [
    "d ${mediaPaths.sourceLibraryRoot}/${library.path} 2775 root media - -"
    "z ${mediaPaths.sourceLibraryRoot}/${library.path} 2775 root media - -"
  ]) mediaLibraries;

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
