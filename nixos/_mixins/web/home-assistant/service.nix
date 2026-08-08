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
    services.home-assistant.enable = true;

    host.internalService.services.home = {
      enable = true;
      upstream = "http://127.0.0.1:${toString port}";
      locationExtraConfig = ''
        proxy_buffering off;
        proxy_read_timeout 3600s;
      '';
    };

    systemd.services.home-assistant = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
    };
  };
}
