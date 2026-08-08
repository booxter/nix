{
  config,
  hostInventory,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.glance;
  hostname = config.networking.hostName;
  dashboards = hostInventory.dashboards;
  settingsFormat = pkgs.formats.yaml { };
  basePort = 18080;
  profiles = lib.imap0 (
    index: profile:
    profile
    // {
      port = basePort + index;
    }
  ) dashboards.profiles;
  localProfiles = builtins.filter (
    profile:
    hostInventory.serviceRunsOn hostname hostInventory.servicesById.${profile.endpointServiceId}
  ) profiles;
  dashboardServiceIds = lib.unique (
    builtins.concatMap (category: category.serviceIds) dashboards.categories
  );
  serviceFor = id: hostInventory.servicesById.${id};
  dashboardServices = map serviceFor dashboardServiceIds;
  resolvedService =
    service:
    if service.scope == "external" then
      service
    else if service.internalEndpointName == null then
      throw "Dashboard service ${service.id} does not expose an internal HTTPS endpoint"
    else
      let
        url = "https://${service.internalEndpointName}.${hostInventory.site.lan.domain}";
      in
      service
      // {
        url = "${url}/";
        probeUrl = "${url}${service.probePath}";
      };
  serviceCatalogById = builtins.listToAttrs (
    map (
      service:
      let
        resolved = resolvedService service;
      in
      {
        name = resolved.id;
        value = resolved;
      }
    ) dashboardServices
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
  sectionsFor =
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
  settingsFor =
    profile:
    let
      searchService = serviceFor profile.search.serviceId;
    in
    (removeAttrs cfg.settings [
      "pages"
      "server"
    ])
    // {
      server = {
        host = "127.0.0.1";
        inherit (profile) port;
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
              ++ map monitorWidgetFor (sectionsFor profile);
            }
          ];
        }
      ];
    };
  inventoryInstances = builtins.listToAttrs (
    map (profile: {
      name = profile.id;
      value = {
        inherit (profile) endpointServiceId port;
        publicAliasServiceIds = profile.publicAliasServiceIds or [ ];
        settings = settingsFor profile;
      };
    }) localProfiles
  );
  instances = cfg.instances;
  unitNameFor = name: "glance-${name}";
  settingsFileFor = name: "/run/${unitNameFor name}/glance.yaml";
  startPreFor =
    name: instance:
    "+"
    + pkgs.writeShellScript "${unitNameFor name}-start-pre" ''
      ${utils.genJqSecretsReplacementSnippet instance.settings (settingsFileFor name)}
      chown "$USER" ${settingsFileFor name}
    '';
  systemdServiceFor =
    name: instance:
    let
      unitName = unitNameFor name;
    in
    {
      description = "Glance ${name} dashboard server";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "nss-user-lookup.target"
      ];
      requires = [ "nss-user-lookup.target" ];
      serviceConfig = {
        ExecStartPre = startPreFor name instance;
        ExecStart = "${lib.getExe cfg.package} --config ${settingsFileFor name}";
        Restart = "on-failure";
        WorkingDirectory = "/var/lib/${unitName}";
        EnvironmentFile = cfg.environmentFile;
        StateDirectory = unitName;
        RuntimeDirectory = unitName;
        RuntimeDirectoryMode = "0755";
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
  internalServiceFor =
    instance:
    let
      endpoint = serviceFor instance.endpointServiceId;
    in
    {
      enable = true;
      upstream = "http://127.0.0.1:${toString instance.port}";
      publicAliases = map (id: (serviceFor id).publicHost) instance.publicAliasServiceIds;
      mtls.enable = endpoint.scope == "external";
    };
  instancePorts = map (instance: instance.port) (builtins.attrValues instances);
  endpointServiceIds = map (instance: instance.endpointServiceId) (builtins.attrValues instances);
in
{
  options.services.glance.instances = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          endpointServiceId = lib.mkOption {
            type = lib.types.str;
            readOnly = true;
            internal = true;
            description = "Inventory service exposing this dashboard instance.";
          };

          port = lib.mkOption {
            type = lib.types.port;
            readOnly = true;
            internal = true;
            description = "Loopback port assigned to this dashboard instance.";
          };

          publicAliasServiceIds = lib.mkOption {
            type = with lib.types; listOf str;
            readOnly = true;
            internal = true;
            description = "Public service names accepted directly by this dashboard endpoint.";
          };

          settings = lib.mkOption {
            type = settingsFormat.type;
            readOnly = true;
            internal = true;
            description = "Rendered Glance configuration for this dashboard instance.";
          };
        };
      }
    );
    readOnly = true;
    internal = true;
    description = "Inventory-driven Glance dashboard instances assigned to this host.";
  };

  config = lib.mkMerge [
    {
      services.glance.instances = inventoryInstances;
    }

    (lib.mkIf (instances != { }) {
      assertions = [
        {
          assertion = !cfg.enable;
          message = "Use services.glance.instances instead of the singleton services.glance service.";
        }
        {
          assertion = builtins.length instancePorts == builtins.length (lib.unique instancePorts);
          message = "Glance instances must use unique loopback ports.";
        }
        {
          assertion = builtins.length endpointServiceIds == builtins.length (lib.unique endpointServiceIds);
          message = "A service endpoint must not expose multiple Glance instances on one host.";
        }
      ];

      systemd.services = lib.mapAttrs' (
        name: instance: lib.nameValuePair (unitNameFor name) (systemdServiceFor name instance)
      ) instances;

      host.internalService.services = lib.mapAttrs' (
        _: instance: lib.nameValuePair instance.endpointServiceId (internalServiceFor instance)
      ) instances;
    })
  ];
}
