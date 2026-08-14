{ config, lib, ... }:
{
  imports = [
    ../../../common/_mixins/observability
    ./alertmanager
    ./alertmanager-watchdog.nix
    ./blackbox.nix
    ./grafana
    ./loki
    ./node-exporter.nix
    ./prometheus-endpoints.nix
    ./prometheus/server.nix
    ./systemd-expectations.nix
    ./textfile-producers.nix
    ./unifi/service.nix
    ./uptimerobot/controller.nix
  ];

  options.host.observability.server = lib.mkOption {
    type = lib.types.nullOr (lib.types.submodule { });
    default = null;
    description = "Central metrics, logs, dashboards, alerting, and network observability stack.";
  };

  config = lib.mkIf (config.host.observability.server != null) {
    host.observability.nodeExporter.mtls.enable = false;
  };
}
