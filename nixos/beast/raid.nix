{
  config,
  lib,
  pkgs,
  ...
}:
let
  smartctlExporterInternalPort = 19633;
  smartctlExporterPort = 9633;
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";
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
  hbaExporter = pkgs.writeShellScript "beast-hba-export" ''
    set -euo pipefail

    exec ${pkgs.python3}/bin/python3 ${./hba-exporter.py} \
      --storcli-path ${pkgs.storcli}/bin/storcli \
      --bay-map /etc/beast-hba-bay-map.json \
      --output-file ${textfileDir}/hba.prom
  '';
in
{
  # Assemble the existing RAID6 array from the previous NAS.
  # Auto-assembly should work; add explicit mdadm config only if needed.
  boot.swraid.enable = true;
  boot.swraid.mdadmConf = "PROGRAM ${pkgs.util-linux}/bin/logger -t mdadm-monitor";
  # Keep md reshape/recovery background I/O gentle so media serving stays responsive.
  boot.kernel.sysctl."dev.raid.speed_limit_max" = 20000;

  # Local disk health monitoring (logs to journal; email relay can be added later).
  services.smartd = {
    enable = true;
    autodetect = true;
  };

  services.prometheus.exporters.smartctl = {
    enable = true;
    port = smartctlExporterInternalPort;
    listenAddress = "127.0.0.1";
    openFirewall = false;
    extraFlags = [
      "--smartctl.path=${pkgs.smartmontools}/bin/smartctl"
      "--smartctl.device-include=^(sd[a-z]+)$"
    ];
  };

  host.observability.client.prometheusMtlsEndpoints.smartctl = {
    enable = true;
    port = smartctlExporterPort;
    upstream = "http://127.0.0.1:${toString smartctlExporterInternalPort}/metrics";
  };

  services.prometheus.exporters.node = {
    enabledCollectors = lib.mkForce [
      "processes"
      "systemd"
      "textfile"
    ];
    # node_exporter 1.10.x cannot parse md raid_disks values like "11 (10)"
    # during reshape, so keep md visibility on this host through our custom
    # textfile exporter instead of the built-in mdadm collector.
    extraFlags = lib.mkForce (
      [
        "--collector.textfile.directory=${textfileDir}"
        "--no-collector.mdadm"
      ]
      ++ lib.optionals config.host.observability.client.nodeExporter.mtls.enable [
        "--web.config.file=${config.sops.templates."node-exporter-web-config.yaml".path}"
      ]
    );
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

  systemd.services.beast-hba-export = {
    description = "Export beast HBA metrics for node exporter";
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = hbaExporter;
    };
  };

  systemd.timers.beast-hba-export = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "45s";
      OnUnitActiveSec = "1min";
      Unit = "beast-hba-export.service";
    };
  };

  systemd.tmpfiles.rules = [
    "d ${textfileDir} 0755 root root - -"
  ];

  environment.systemPackages = with pkgs; [
    hdparm
    lm_sensors
    mdadm
    nvme-cli
    smartmontools
  ];
}
