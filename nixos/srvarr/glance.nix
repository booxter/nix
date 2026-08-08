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
  dashboards = hostInventory.dashboards;
  internalProfile = dashboards.profilesById.internal;
  publicProfile = dashboards.profilesById.public;
  dashService = hostInventory.servicesById.${publicProfile.endpointServiceId};
  dashboardServiceIds = lib.unique (
    builtins.concatMap (category: category.serviceIds) dashboards.categories
  );
  dashboardServices = map (id: hostInventory.servicesById.${id}) dashboardServiceIds;
  fanaHostConfig = outputs.nixosConfigurations.fana.config;
  fanaHttpsServices = fanaHostConfig.host.internalService.services;
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
  ) dashboardServices;
  serviceCatalogById = builtins.listToAttrs (
    map (service: {
      name = service.id;
      value = service;
    }) serviceCatalog
  );
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
    profile:
    map (
      categoryId:
      let
        category = dashboards.categoriesById.${categoryId};
      in
      {
        inherit (category) title;
        sites = map (id: serviceCatalogById.${id}) category.serviceIds ++ (category.links or [ ]);
      }
    ) profile.categoryIds;
  mkGlanceSettings =
    {
      port,
      profile,
      sections,
    }:
    let
      searchService = hostInventory.servicesById.${profile.search.serviceId};
    in
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
                  search-engine = "${searchService.url}${profile.search.queryPath}";
                }
              ]
              ++ map monitorWidgetFor sections;
            }
          ];
        }
      ];
    };
  allServiceSections = serviceSectionsFor internalProfile;
  externalServiceSections = serviceSectionsFor publicProfile;
  externalSettings = mkGlanceSettings {
    port = glanceExternalPort;
    profile = publicProfile;
    sections = externalServiceSections;
  };
  externalSettingsFile = (pkgs.formats.yaml { }).generate "glance-external.yaml" externalSettings;
in
{
  services.glance = {
    enable = true;
    settings = mkGlanceSettings {
      port = glanceInternalPort;
      profile = internalProfile;
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
