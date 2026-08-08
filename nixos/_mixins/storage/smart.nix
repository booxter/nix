{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.storage.smart;
  metricsEnabled = cfg.enable && config.host.observability.enable;
  smartctlExporterInternalPort = 19633;
  smartctlExporterPort = 9633;
  restartUnits = [
    "smartd.service"
  ]
  ++ lib.optional metricsEnabled "prometheus-smartctl-exporter.service";
in
{
  options.host.storage.smart = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.host.storage.diskBays != null;
      description = "Whether to monitor local storage devices with SMART.";
    };

    deviceIncludeRegex = lib.mkOption {
      type = lib.types.str;
      default = "^(sd[a-z]+)$";
      description = "Device-name regular expression passed to the smartctl exporter.";
    };

    hotplugKernelPattern = lib.mkOption {
      type = lib.types.str;
      default = "sd*";
      description = "Kernel device-name pattern whose changes trigger SMART rediscovery.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      services.smartd = {
        enable = true;
        autodetect = true;
      };

      # smartd discovers DEVICESCAN devices only at startup. Restart enabled
      # SMART consumers when whole disks change so hotplugged and late HBA
      # devices converge immediately.
      services.udev.extraRules = ''
        ACTION=="add|change|move|remove", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="${cfg.hotplugKernelPattern}", RUN+="${config.systemd.package}/bin/systemctl --no-block restart ${lib.concatStringsSep " " restartUnits}"
      '';

      environment.systemPackages = [ pkgs.smartmontools ];
    })

    (lib.mkIf metricsEnabled {
      services.prometheus.exporters.smartctl = {
        enable = true;
        port = smartctlExporterInternalPort;
        listenAddress = "127.0.0.1";
        extraFlags = [
          "--smartctl.path=${pkgs.smartmontools}/bin/smartctl"
          "--smartctl.device-include=${cfg.deviceIncludeRegex}"
        ];
      };

      # Resolve the sd device group before the exporter service starts so the
      # upstream DeviceAllow=block-sd rule is installed on NVMe-root hosts.
      systemd.services.prometheus-smartctl-exporter = {
        wants = [ "modprobe@sd_mod.service" ];
        after = [ "modprobe@sd_mod.service" ];
      };

      host.observability.metricsEndpoints.smartctl = {
        enable = true;
        port = smartctlExporterPort;
        upstream = "http://127.0.0.1:${toString smartctlExporterInternalPort}/metrics";
        scrape = {
          enable = true;
          component = "smartctl";
          profile = "hardware";
        };
      };
    })
  ];
}
