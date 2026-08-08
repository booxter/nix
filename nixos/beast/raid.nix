{
  config,
  pkgs,
  ...
}:
let
  smartctlExporterInternalPort = 19633;
  smartctlExporterPort = 9633;
in
{
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

  host.observability.prometheusEndpoints.smartctl = {
    enable = true;
    port = smartctlExporterPort;
    upstream = "http://127.0.0.1:${toString smartctlExporterInternalPort}/metrics";
  };

  environment.systemPackages = with pkgs; [
    hdparm
    lm_sensors
    nvme-cli
    smartmontools
  ];
}
