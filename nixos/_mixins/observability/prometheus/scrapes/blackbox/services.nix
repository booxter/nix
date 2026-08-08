{
  blackboxHttpMtlsTlsConfig,
  config,
  grafanaPort,
  hostInventory,
  lib,
  outputs,
}:
let
  realmName = config.host.realm;
  blackboxAddress = "127.0.0.1:${toString config.services.prometheus.exporters.blackbox.port}";
  blackboxServices = builtins.filter (service: service.blackboxProbe) hostInventory.services;
  publicServices = hostInventory.publicServices;
  beastConfig = outputs.nixosConfigurations.beast.config;
  publicWanHost = beastConfig.host.externalService.ddns.hostname;
  publicWanProbeUrlFor = service: "https://${publicWanHost}${service.probePath}";

  srvarrConfig = outputs.nixosConfigurations.srvarr.config;
  srvarrPortFor =
    serviceId:
    {
      aurral = srvarrConfig.systemd.services.aurral.environment.PORT;
      audiobookshelf = srvarrConfig.services.audiobookshelf.port;
      pinepods = srvarrConfig.systemd.services.podman-pinepods.environment.PINEPODS_LISTEN_PORT;
      bazarr = srvarrConfig.services.bazarr.listenPort;
      houndarr = srvarrConfig.systemd.services.houndarr.environment.HOUNDARR_PORT;
      lidarr = srvarrConfig.services.lidarr.settings.server.port;
      prowlarr = srvarrConfig.services.prowlarr.settings.server.port;
      radarr = srvarrConfig.services.radarr.settings.server.port;
      sabnzbd = srvarrConfig.services.sabnzbd.settings.misc.port;
      shelfmark = srvarrConfig.services.shelfmark.environment.FLASK_PORT;
      sonarr = srvarrConfig.services.sonarr.settings.server.port;
      transmission = srvarrConfig.services.transmission.settings.rpc-port;
    }
    .${serviceId};
  instanceConfigFor =
    service:
    if hostInventory.serviceRunsOn config.networking.hostName service then
      config
    else
      outputs.nixosConfigurations.${hostInventory.serviceHost service}.config;
  httpsServiceFor =
    service:
    let
      services = (instanceConfigFor service).host.internalService.services;
    in
    if builtins.hasAttr service.id services && services.${service.id}.enable then
      services.${service.id}
    else
      null;
  mkInstanceProbe =
    service: probePath: useProbeListener:
    let
      httpsService = httpsServiceFor service;
      probePortSuffix = lib.optionalString (
        useProbeListener && httpsService.probe.port != 443
      ) ":${toString httpsService.probe.port}";
    in
    if httpsService != null then
      {
        blackboxModule = if httpsService.mtls.enable then "http_service_mtls" else "http_service";
        probeUrl = "https://${httpsService.serverName}${probePortSuffix}${probePath}";
        url = "https://${httpsService.serverName}/";
      }
    else if hostInventory.serviceRunsOn config.networking.hostName service then
      {
        probeUrl = "http://127.0.0.1:${toString grafanaPort}/${probePath}";
        url = "http://${service.displayHost}:3000/";
      }
    else if hostInventory.serviceRunsOn "srvarr" service then
      {
        probeUrl = "http://${service.probeHost}:${toString (srvarrPortFor service.id)}${probePath}";
        url = "http://${service.displayHost}:${toString (srvarrPortFor service.id)}/";
      }
    else
      throw "Blackbox service ${service.id} must expose enabled internal HTTPS";

  inventoryCatalog = map (
    service:
    if service.scope == "external" then
      service
    else
      service // (mkInstanceProbe service service.probePath false)
  ) blackboxServices;
  backendCatalog = map (
    service:
    let
      instanceProbe = mkInstanceProbe service service.backendProbe.path true;
    in
    service
    // instanceProbe
    // {
      blackboxModule =
        service.backendProbe.blackboxModule or (instanceProbe.blackboxModule or "http_service");
      backend_probe = service.backendProbe.name or "http";
      backend_probe_title = service.backendProbe.title or "Backend HTTP";
      scope = "backend";
    }
  ) (builtins.filter (service: service ? backendProbe) blackboxServices);
  usesHttpMtls = builtins.any (service: (service.blackboxModule or null) == "http_service_mtls") (
    inventoryCatalog ++ backendCatalog
  );

  lan = hostInventory.site.lan;
  realmProxmox = hostInventory.realms.${realmName}.services.proxmox;
  proxmoxNodeNames = lib.unique (
    lib.concatMap (cluster: cluster.nodes) (builtins.attrValues realmProxmox.clusters)
  );
  proxmoxApiNodeNames = builtins.filter (
    name: outputs.nixosConfigurations.${name}.config.host.proxmox.apiCertificate.enable
  ) proxmoxNodeNames;
  httpsUrlFor = host: port: "https://${host}${lib.optionalString (port != 443) ":${toString port}"}/";
  proxmoxCatalog = map (
    name:
    let
      hostConfig = outputs.nixosConfigurations.${name}.config;
      apiCertificate = hostConfig.host.proxmox.apiCertificate;
      url = httpsUrlFor apiCertificate.serverName apiCertificate.publicPort;
    in
    {
      id = "proxmox-${hostConfig.networking.hostName}";
      scope = "internal";
      title = "Proxmox ${hostConfig.networking.hostName}";
      probeUrl = url;
      inherit url;
    }
  ) proxmoxApiNodeNames;
  serviceCatalog =
    inventoryCatalog
    ++ [
      {
        id = "proxmox";
        scope = "internal";
        title = "Proxmox VE";
        probeUrl = "https://proxmox.${lan.domain}/";
        url = "https://proxmox.${lan.domain}/";
      }
    ]
    ++ proxmoxCatalog
    ++ [
      {
        id = "unifi";
        scope = "internal";
        title = "UniFi Console";
        probeUrl = "https://unifi.${lan.domain}/";
        url = "https://unifi.${lan.domain}/";
        tlsRotation = "manual";
      }
    ];

  httpServiceModule = config.host.observability.blackbox.baseModules.http_service;
  modules = lib.optionalAttrs usesHttpMtls {
    http_service_mtls = httpServiceModule // {
      http = httpServiceModule.http // {
        tls_config = blackboxHttpMtlsTlsConfig;
      };
    };
  };
  mkStaticConfig = service: {
    labels = {
      availability = service.observability.availability or "always";
      component = "blackbox";
      module = service.blackboxModule or "http_service";
      probe_family = "service";
      probe_protocol = "http";
      probe_role = if service.scope == "backend" then "backend" else "frontdoor";
      probe_title = if service.scope == "backend" then "Backend" else "Front door";
      realm = realmName;
      scrape_profile = "probe";
      scope = service.scope;
      service = service.id;
      service_title = service.title;
    }
    // lib.optionalAttrs (service ? tlsRotation) {
      tls_rotation = service.tlsRotation;
    }
    // lib.optionalAttrs (service ? backend_probe) {
      inherit (service) backend_probe backend_probe_title;
    };
    targets = [ service.probeUrl ];
  };
  relabelConfigs = [
    {
      source_labels = [ "module" ];
      target_label = "__param_module";
    }
    {
      source_labels = [ "__address__" ];
      target_label = "__param_target";
    }
    {
      source_labels = [ "__param_target" ];
      target_label = "target";
    }
    {
      source_labels = [ "service" ];
      target_label = "instance";
    }
    {
      replacement = blackboxAddress;
      target_label = "__address__";
    }
    {
      action = "labeldrop";
      regex = "module";
    }
  ];
  mkScrapeConfig = jobName: catalog: {
    job_name = jobName;
    metrics_path = "/probe";
    static_configs = map mkStaticConfig catalog;
    relabel_configs = relabelConfigs;
  };
in
{
  inherit modules usesHttpMtls;

  scrapeConfigs = [
    (mkScrapeConfig "blackbox-arr" serviceCatalog)
    (mkScrapeConfig "blackbox-backend" backendCatalog)
    {
      job_name = "blackbox-public-wan";
      metrics_path = "/probe";
      params.module = [ "http_service" ];
      static_configs = map (service: {
        labels = {
          availability = service.observability.availability or "always";
          component = "blackbox";
          probe_family = "service";
          probe_protocol = "http";
          probe_role = "public-wan";
          probe_title = "Public WAN";
          realm = realmName;
          scrape_profile = "probe";
          scope = "external";
          service = service.id;
          service_title = service.title;
          public_host = service.publicHost;
        };
        targets = [ (publicWanProbeUrlFor service) ];
      }) publicServices;
      relabel_configs = [
        {
          source_labels = [ "__address__" ];
          target_label = "__param_target";
        }
        {
          source_labels = [ "public_host" ];
          target_label = "__param_hostname";
        }
        {
          source_labels = [ "__param_target" ];
          target_label = "target";
        }
        {
          source_labels = [ "service" ];
          target_label = "instance";
        }
        {
          replacement = blackboxAddress;
          target_label = "__address__";
        }
      ];
    }
  ];
}
