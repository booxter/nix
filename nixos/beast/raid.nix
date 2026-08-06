{
  beastPkgs,
  config,
  lib,
  pkgs,
  ...
}:
let
  smartctlExporterInternalPort = 19633;
  smartctlExporterPort = 9633;
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";
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
  # smartd only discovers DEVICESCAN devices on start, and the exporter's
  # built-in 10 minute rescan is too slow for RAID hotplug or late HBA attach.
  # Similar smartd-only pattern:
  # https://github.com/Zocker1999NET/server/blob/353caf1dae9b51e641731275f05e856b4d0dca08/nix/nixosProfiles/common.nix
  # Restart both services when whole /dev/sdX disks change so they converge
  # immediately after adds, removes, and replacements.
  services.udev.extraRules = ''
    ACTION=="add|change|move|remove", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd*", RUN+="${config.systemd.package}/bin/systemctl --no-block restart smartd.service prometheus-smartctl-exporter.service"
  '';

  services.prometheus.exporters.smartctl = {
    enable = true;
    port = smartctlExporterInternalPort;
    listenAddress = "127.0.0.1";
    extraFlags = [
      "--smartctl.path=${pkgs.smartmontools}/bin/smartctl"
      "--smartctl.device-include=^(sd[a-z]+)$"
    ];
  };
  # Resolve the "sd" device group before the exporter service starts so the
  # upstream DeviceAllow=block-sd rule is installed even on NVMe-root hosts.
  systemd.services.prometheus-smartctl-exporter = {
    wants = [ "modprobe@sd_mod.service" ];
    after = [ "modprobe@sd_mod.service" ];
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
    extraFlags = [ "--no-collector.mdadm" ];
  };
  systemd.services.beast-md-sync-export = {
    description = "Export md sync status for node exporter";
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.escapeShellArgs [
        "${beastPkgs.storage-observability}/bin/beast-md-metrics"
        "--output-file"
        "${textfileDir}/md-sync.prom"
      ];
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
      ExecStart = lib.escapeShellArgs [
        (lib.getExe beastPkgs.storage-observability)
        "--bay-map"
        "/etc/beast-hba-bay-map.json"
        "--output-file"
        "${textfileDir}/hba.prom"
      ];
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
