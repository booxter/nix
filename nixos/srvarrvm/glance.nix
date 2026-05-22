{
  config,
  hostInventory,
  lib,
  ...
}:
let
  srvarrPorts = {
    aurral = config.systemd.services.aurral.environment.PORT;
    audiobookshelf = config.nixarr.audiobookshelf.port;
    bazarr = config.nixarr.bazarr.port;
    lidarr = config.nixarr.lidarr.port;
    prowlarr = config.nixarr.prowlarr.port;
    radarr = config.nixarr.radarr.port;
    sabnzbd = config.nixarr.sabnzbd.guiPort;
    shelfmark = config.nixarr.shelfmark.port;
    sonarr = config.nixarr.sonarr.port;
    transmission = config.nixarr.transmission.uiPort;
  };
  serviceCatalog = map (
    service:
    if service.scope == "external" then
      service
    else if service.owner == "fana" then
      service
      // {
        url = "http://${service.displayHost}:3000/";
      }
    else
      service
      // {
        url = "http://${service.displayHost}:${toString srvarrPorts.${service.id}}/";
      }
  ) hostInventory.services;
in
{
  services.glance = {
    enable = true;
    openFirewall = true;
    settings = {
      server = {
        host = "0.0.0.0";
        port = 80;
      };
      pages = [
        {
          name = "Startpage";
          width = "slim";
          hide-desktop-navigation = true;
          center-vertically = true;
          columns = [
            {
              size = "full";
              widgets = [
                {
                  type = "search";
                  autofocus = true;
                }
                {
                  type = "monitor";
                  cache = "1m";
                  title = "Services";
                  sites = map (service: {
                    inherit (service)
                      icon
                      title
                      url
                      ;
                  }) serviceCatalog;
                }
              ];
            }
          ];
        }
      ];
    };
  };

  # Allow glance to bind to lower port, 80
  systemd.services.glance.serviceConfig = {
    AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
    CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
    NoNewPrivileges = false;
    PrivateUsers = lib.mkForce false;
  };
}
