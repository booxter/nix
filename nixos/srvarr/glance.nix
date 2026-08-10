{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  glanceInternalPort = 18080;
  glanceExternalPort = 18081;
  glanceCategories = [
    {
      id = "user";
      title = "User Apps";
    }
    {
      id = "media-admin";
      title = "Media Admin";
    }
    {
      id = "infrastructure";
      title = "Infrastructure";
    }
  ];
  fleetServices = import ../_lib/fleet-web-services.nix {
    inherit config lib outputs;
  };
  dashService = fleetServices.byId.dash;
  degoogService = fleetServices.byId.goo;
  pkiAuthority = config.host.internalPki.realmAuthority;
  pkiRootCaUrl = "${pkiAuthority.url}${pkiAuthority.rootsPath}";
  serviceCatalog = map (
    contribution:
    let
      service = contribution.value;
      baseUrl = if service.public.enable then service.public.url else service.internal.url;
    in
    {
      inherit (service.presentation) icon title;
      category = service.presentation.dashboard.category;
      url = "${baseUrl}/";
      probeUrl = "${baseUrl}${service.health.frontend.path}";
    }
  ) fleetServices.dashboard;
  infrastructureLinks = [
    {
      icon = "sh:proxmox";
      title = "Proxmox VE";
      url = "https://proxmox.${config.host.network.lanDomain}/";
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
    category: builtins.filter (service: service.category == category.id) serviceCatalog;
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
                  search-engine = "${degoogService.public.url}/search?q={QUERY}";
                }
              ]
              ++ map monitorWidgetFor sections;
            }
          ];
        }
      ];
    };
  allServiceSections = serviceSectionsFor glanceCategories;
  externalServiceSections = serviceSectionsFor (
    builtins.filter (category: category.id == "user") glanceCategories
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

  host.web.services = {
    glance = {
      enable = true;
      upstream = "http://127.0.0.1:${toString glanceInternalPort}";
      internal.publicAliases = [ dashService.public.hostName ];
    };

    dash = {
      enable = true;
      upstream = "http://127.0.0.1:${toString glanceExternalPort}";
      public = {
        enable = true;
        hostName = "dash.${config.host.network.publicDomain}";
        serveOnOwner = false;
        splitDnsHost = config.networking.hostName;
      };
      health.frontend.enable = true;
      presentation = {
        title = "Dashboard";
        icon = "sh:glance";
      };
    };
  };
}
