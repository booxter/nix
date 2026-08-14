{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.hardware.storage.mdraid;
  observabilityEnabled = config.host.observability.enable;
  textfileDir = config.host.observability.nodeExporter.textfile.directories.default;
in
{
  config = lib.mkIf cfg.enable {
    boot.swraid = {
      enable = true;
      mdadmConf = "PROGRAM ${pkgs.util-linux}/bin/logger -t mdadm-monitor";
    };

    boot.kernel.sysctl = lib.mkIf (cfg.recoverySpeedLimitMax != null) {
      "dev.raid.speed_limit_max" = cfg.recoverySpeedLimitMax;
    };

    environment.systemPackages = [ pkgs.mdadm ];

    # node_exporter cannot parse transient raid_disks values such as
    # "11 (10)" during reshape, so use the dedicated sysfs collector.
    services.prometheus.exporters.node.extraFlags = lib.mkIf observabilityEnabled [
      "--no-collector.mdadm"
    ];

    host.observability.nodeExporter.textfile.periodicProducers = lib.mkIf observabilityEnabled {
      mdraid-metrics = {
        description = "Export Linux MD status for node exporter";
        after = [ "local-fs.target" ];
        command = [
          (lib.getExe' pkgs.storage-observability "storage-md-metrics")
          "--output-file"
          "${textfileDir}/md-sync.prom"
        ];
        interval = "1min";
        onBootSec = "30s";
      };
    };
  };
}
