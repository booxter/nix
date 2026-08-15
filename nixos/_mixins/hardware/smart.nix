{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.hardware.storage.smart;
  observabilityEnabled = config.host.observability.enable;
  exporterInternalPort = 19633;
  exporterPort = 9633;
  monitoredServices = [
    "smartd.service"
  ]
  ++ lib.optional observabilityEnabled "prometheus-smartctl-exporter.service";
in
{
  config = lib.mkIf cfg.enable {
    services.smartd = {
      enable = true;
      autodetect = true;
    };

    # Rescan immediately when whole disks appear or disappear. smartd and
    # smartctl_exporter otherwise discover late HBA attachments slowly.
    services.udev.extraRules = ''
      ACTION=="add|change|move|remove", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd*|nvme*", RUN+="${config.systemd.package}/bin/systemctl --no-block restart ${lib.concatStringsSep " " monitoredServices}"
    '';

    environment.systemPackages = [
      pkgs.hdparm
      pkgs.smartmontools
    ];

    services.prometheus.exporters.smartctl = lib.mkIf observabilityEnabled {
      enable = true;
      port = exporterInternalPort;
      listenAddress = "127.0.0.1";
      extraFlags = [
        "--smartctl.path=${pkgs.smartmontools}/bin/smartctl"
        "--smartctl.device-include=${cfg.devicePattern}"
      ];
    };

    # Resolve the sd device group before service sandboxing is assembled.
    systemd.services.prometheus-smartctl-exporter = lib.mkIf observabilityEnabled {
      wants = [ "modprobe@sd_mod.service" ];
      after = [ "modprobe@sd_mod.service" ];
    };

    host.observability.prometheusEndpoints.smartctl = lib.mkIf observabilityEnabled {
      port = exporterPort;
      upstream = "http://127.0.0.1:${toString exporterInternalPort}/metrics";
      scrape = {
        profile = "hardware";
        component = "smartctl";
      };
    };
  };
}
