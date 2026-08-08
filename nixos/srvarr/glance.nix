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
  glanceServices = builtins.filter (service: service.showInGlance) hostInventory.services;
  dashService = hostInventory.servicesById.dash;
  degoogService = hostInventory.servicesById.goo;
  fanaHostConfig = outputs.nixosConfigurations.fana.config;
  fanaHttpsServices = fanaHostConfig.host.internalService.services;
  internalPki = hostInventory.realms.${config.host.realm}.services.internalPki;
  pkiRootCaUrl =
    "https://${internalPki.providerHost}:"
    + toString internalPki.server.port
    + internalPki.server.rootsPath;
  srvarrHttpsServices = config.host.internalService.services;
  internalServicesFor =
    service:
    if hostInventory.serviceRunsOn "srvarr" service then
      srvarrHttpsServices
    else if hostInventory.serviceRunsOn "fana" service then
      fanaHttpsServices
    else
      outputs.nixosConfigurations.${hostInventory.serviceHost service}.config.host.internalService.services;
  internalServiceFor =
    service:
    let
      internalServices = internalServicesFor service;
      serviceConfig = builtins.getAttr service.id internalServices;
    in
    if builtins.hasAttr service.id internalServices && serviceConfig.enable then
      serviceConfig
    else
      throw "Glance service ${service.id} must expose enabled internal HTTPS";
  serviceCatalog = map (
    service:
    if service.scope == "external" then
      service
    else
      let
        httpsService = internalServiceFor service;
      in
      service
      // {
        url = "https://${httpsService.serverName}/";
        probeUrl = "https://${httpsService.serverName}${service.probePath}";
      }
  ) glanceServices;
  infrastructureLinks = [
    {
      icon = "sh:proxmox";
      title = "Proxmox VE";
      url = "https://proxmox.${hostInventory.site.lan.domain}/";
    }
    {
      icon = "sh:smallstep";
      title = "PKI Root CA";
      url = pkiRootCaUrl;
    }
  ];
  extraSitesByCategory = {
    infrastructure = infrastructureLinks;
  };
  extraSitesFor =
    category:
    if builtins.hasAttr category.id extraSitesByCategory then
      builtins.getAttr category.id extraSitesByCategory
    else
      [ ];
  servicesForCategory =
    category: builtins.filter (service: service.glanceCategory == category.id) serviceCatalog;
  siteFor =
    site:
    {
      inherit (site)
        icon
        title
        url
        ;
    }
    // lib.optionalAttrs (site ? probeUrl) {
      check-url = site.probeUrl;
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
                  search-engine = "${degoogService.url}/search?q={QUERY}";
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

  host.internalService.services = {
    glance = {
      enable = true;
      upstream = "http://127.0.0.1:${toString glanceInternalPort}";
      publicAliases = [ dashService.publicHost ];
    };

    dash = {
      enable = true;
      upstream = "http://127.0.0.1:${toString glanceExternalPort}";
      mtls.enable = true;
    };
  };
}
