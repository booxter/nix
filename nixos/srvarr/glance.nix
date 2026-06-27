{
  config,
  hostInventory,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  glanceInternalPort = 18080;
  glanceExternalPort = 18081;
  dashService = hostInventory.servicesById.dash;
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
  utilityLinks = [
    {
      icon = "sh:smallstep";
      title = "PKI Root CA";
      url = pkiRootCaUrl;
    }
  ];
  extraSitesByCategory = {
    infrastructure = utilityLinks;
  };
  extraSitesFor =
    category:
    if builtins.hasAttr category.id extraSitesByCategory then
      builtins.getAttr category.id extraSitesByCategory
    else
      [ ];
  servicesForCategory =
    category: builtins.filter (service: service.glanceCategory == category.id) serviceCatalog;
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
  serviceSectionsFor =
    categories:
    map (category: {
      inherit (category) title;
      sites = (servicesForCategory category) ++ (extraSitesFor category);
    }) categories;
  mkGlanceSettings =
    {
      port,
      sections,
    }:
    {
      server = {
        host = "127.0.0.1";
        inherit port;
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
              ++ map monitorWidgetFor sections;
            }
          ];
        }
      ];
    };
  allServiceSections = serviceSectionsFor hostInventory.glanceCategories;
  externalServiceSections = serviceSectionsFor (
    builtins.filter (category: category.id == "user") hostInventory.glanceCategories
  );
  externalSettings = mkGlanceSettings {
    port = glanceExternalPort;
    sections = externalServiceSections;
  };
  externalSettingsFile = (pkgs.formats.yaml { }).generate "glance-external.yaml" externalSettings;
in
{
  services.glance = {
    enable = true;
    settings = mkGlanceSettings {
      port = glanceInternalPort;
      sections = allServiceSections;
    };
  };

  systemd.services.glance-external = {
    description = "Glance external dashboard server";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network.target"
      "nss-user-lookup.target"
    ];
    requires = [ "nss-user-lookup.target" ];
    serviceConfig = {
      ExecStart = "${lib.getExe config.services.glance.package} --config ${externalSettingsFile}";
      Restart = "on-failure";
      WorkingDirectory = "/var/lib/glance-external";
      StateDirectory = "glance-external";
      PrivateTmp = true;
      DynamicUser = true;
      DevicePolicy = "closed";
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      PrivateUsers = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      ProcSubset = "all";
      RestrictNamespaces = true;
      RestrictRealtime = true;
      SystemCallArchitectures = "native";
      UMask = "0077";
    };
  };

  host.internalHttps.services = {
    glance = {
      enable = true;
      upstream = "http://127.0.0.1:${toString glanceInternalPort}";
      serverAliases = [ dashService.publicHost ];
    };

    dash = {
      enable = true;
      upstream = "http://127.0.0.1:${toString glanceExternalPort}";
      mtls.enable = true;
    };
  };
}
