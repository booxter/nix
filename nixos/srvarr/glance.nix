{
  config,
  hostInventory,
  outputs,
  ...
}:
let
  glanceInternalPort = 18080;
  fanaHostConfig = outputs.nixosConfigurations.fana.config;
  fanaHttpsServices = fanaHostConfig.host.internalHttps.services;
  pkiSpec = hostInventory.nixosHostSpecsByName.pki;
  pkiCaServer = pkiSpec.caServer;
  pkiRootCaUrl =
    "https://${hostInventory.toNixosPrimaryDnsName pkiSpec}:"
    + toString pkiCaServer.port
    + pkiCaServer.rootsPath;
  srvarrHttpsServices = config.host.internalHttps.services;
  srvarrPortFor =
    serviceId:
    {
      aurral = config.systemd.services.aurral.environment.PORT;
      audiobookshelf = config.services.audiobookshelf.port;
      bazarr = config.services.bazarr.listenPort;
      lidarr = config.services.lidarr.settings.server.port;
      prowlarr = config.services.prowlarr.settings.server.port;
      radarr = config.services.radarr.settings.server.port;
      sabnzbd = config.services.sabnzbd.settings.misc.port;
      shelfmark = config.services.shelfmark.environment.FLASK_PORT;
      sonarr = config.services.sonarr.settings.server.port;
      transmission = config.services.transmission.settings.rpc-port;
    }
    .${serviceId};
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
        url = "http://${service.displayHost}:${toString (srvarrPortFor service.id)}/";
      }
  ) hostInventory.glanceServices;
  serviceCatalogById = builtins.listToAttrs (
    map (service: {
      name = service.id;
      value = service;
    }) serviceCatalog
  );
  servicesIn = serviceIds: map (serviceId: serviceCatalogById.${serviceId}) serviceIds;
  utilityLinks = [
    {
      icon = "sh:smallstep";
      title = "PKI Root CA";
      url = pkiRootCaUrl;
    }
  ];
  siteFor = site: {
    inherit (site)
      icon
      title
      url
      ;
  };
  monitorWidgetFor = section: {
    type = "monitor";
    cache = "1m";
    inherit (section) title;
    sites = map siteFor section.sites;
  };
  serviceSections = [
    {
      title = "User Apps";
      sites = servicesIn [
        "jellyfin"
        "seerr"
        "romm"
        "aurral"
        "audiobookshelf"
        "shelfmark"
        "vikunja"
        "paperless"
        "ai"
      ];
    }
    {
      title = "Media Admin";
      sites = servicesIn [
        "radarr"
        "sonarr"
        "lidarr"
        "bazarr"
        "prowlarr"
        "transmission"
        "sabnzbd"
      ];
    }
    {
      title = "Infrastructure";
      sites =
        (servicesIn [
          "llm"
          "grafana"
        ])
        ++ utilityLinks;
    }
  ];
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
              ]
              ++ map monitorWidgetFor serviceSections;
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
