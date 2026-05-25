{
  config,
  hostInventory,
  outputs,
  ...
}:
let
  glanceInternalPort = 18080;
  fanaHostConfig = outputs.nixosConfigurations.prox-fanavm.config;
  fanaHttpsServices = fanaHostConfig.host.internalHttps.services;
  srvarrHttpsServices = config.host.internalHttps.services;
  srvarrPorts = {
    inherit (config.host.srvarr.services)
      aurral
      audiobookshelf
      bazarr
      lidarr
      prowlarr
      radarr
      sabnzbd
      shelfmark
      sonarr
      transmission
      ;
  };
  httpsServiceFor =
    service:
    if
      builtins.hasAttr service.id srvarrHttpsServices
      && (builtins.getAttr service.id srvarrHttpsServices).enable
    then
      builtins.getAttr service.id srvarrHttpsServices
    else
      null;
  fanaHttpsServiceFor =
    service:
    if
      builtins.hasAttr service.id fanaHttpsServices
      && (builtins.getAttr service.id fanaHttpsServices).enable
    then
      builtins.getAttr service.id fanaHttpsServices
    else
      null;
  serviceCatalog = map (
    service:
    let
      httpsService = httpsServiceFor service;
      fanaHttpsService = fanaHttpsServiceFor service;
    in
    if service.scope == "external" then
      service
    else if service.owner == "fana" && fanaHttpsService != null then
      service
      // {
        url = "https://${fanaHttpsService.serverName}/";
      }
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
        url = "http://${service.displayHost}:${toString srvarrPorts.${service.id}.port}/";
      }
  ) hostInventory.services;
in
{
  services.glance = {
    enable = true;
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
