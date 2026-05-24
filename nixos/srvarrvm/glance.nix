{
  config,
  hostInventory,
  ...
}:
let
  glanceInternalPort = 18080;
  srvarrHttpsServices = config.host.internalHttps.services;
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
  httpsServiceFor =
    service:
    if builtins.hasAttr service.id srvarrHttpsServices && (builtins.getAttr service.id srvarrHttpsServices).enable then
      builtins.getAttr service.id srvarrHttpsServices
    else
      null;
  serviceCatalog = map (
    service:
    let
      httpsService = httpsServiceFor service;
    in
    if service.scope == "external" then
      service
    else if service.owner == "fana" then
      service
      // {
        url = "http://${service.displayHost}:3000/";
      }
    else if httpsService != null then
      service
      // {
        url = "https://${httpsService.serverName}/";
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
    openFirewall = false;
    settings = {
      server = {
        host = "127.0.0.1";
        port = glanceInternalPort;
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

  host.internalHttps.services.glance = {
    enable = true;
    upstream = "http://127.0.0.1:${toString glanceInternalPort}";
  };
}
