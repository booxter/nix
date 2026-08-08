{
  config,
  hostInventory,
  lib,
  ...
}:
let
  service = hostInventory.servicesById.home;
  isOwner = service.owner == config.networking.hostName;
  port = config.services.home-assistant.config.http.server_port;
in
{
  config = lib.mkIf isOwner {
    host.observability.prometheusEndpoints.home-assistant = {
      enable = true;
      port = 9346;
      upstream = "http://127.0.0.1:${toString port}/api/prometheus";
    };
  };
}
