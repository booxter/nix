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
  internalHttpsServicesFor =
    service: if service.owner == "fana" then fanaHttpsServices else srvarrHttpsServices;
  internalHttpsServiceFor =
    service:
    let
      internalHttpsServices = internalHttpsServicesFor service;
      serviceConfig = builtins.getAttr service.id internalHttpsServices;
    in
    if builtins.hasAttr service.id internalHttpsServices && serviceConfig.enable then
      serviceConfig
    else
      throw "Glance service ${service.id} must expose enabled internal HTTPS";
  serviceCatalog = map (
    service:
    if service.scope == "external" then
      service
    else
      let
        httpsService = internalHttpsServiceFor service;
      in
      service
      // {
        url = "https://${httpsService.serverName}/";
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
