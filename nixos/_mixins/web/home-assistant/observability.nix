{
  config,
  hostInventory,
  lib,
  ...
}:
let
  service = hostInventory.servicesById.home;
  isLocal = hostInventory.serviceRunsOn config.networking.hostName service;
  port = config.services.home-assistant.config.http.server_port;
in
{
  config = lib.mkIf isLocal {
    host.observability.prometheusEndpoints.home-assistant = {
      enable = true;
      port = 9346;
      upstream = "http://127.0.0.1:${toString port}/api/prometheus";
    };
  };
}
