{ config, lib, ... }:
let
  cfg = config.host.observability;
in
{
  config = lib.mkMerge [
    {
      host.observability.nodeExporter.mtls.enable = lib.mkDefault (!config.host.isWork);
    }
    (lib.mkIf cfg.enable {
      host.observability.nodeExporter = {
        serviceUser = config.launchd.daemons.prometheus-node-exporter.serviceConfig.UserName;
        serviceGroup = config.launchd.daemons.prometheus-node-exporter.serviceConfig.GroupName;
      };

      services.prometheus.exporters.node = {
        enable = true;
        listenAddress = cfg.nodeExporter.listenAddress;
        disabledCollectors = lib.mkIf config.host.observability.thermal.enable [ "thermal" ];
      };
    })
  ];
}
