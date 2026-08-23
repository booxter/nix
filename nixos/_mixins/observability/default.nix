{
  config,
  fleetInventory,
  lib,
  ...
}:
let
  hostName = config.networking.hostName;
  realmInventory = fleetInventory.observability.realms.${config.host.realm} or null;
  serverHost = if realmInventory == null then null else realmInventory.prometheusServer;
in
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
    default = if serverHost == hostName then { } else null;
    readOnly = true;
    internal = true;
    description = "Central metrics, logs, dashboards, alerting, and network observability stack.";
  };

  config = lib.mkMerge [
    {
      _module.args.observabilityCatalog = import ../../../lib/observability/catalog.nix {
        inherit fleetInventory lib;
      };
    }
    (lib.mkIf (config.host.observability.server != null) {
      host.observability.nodeExporter.mtls.enable = false;
    })
  ];
}
