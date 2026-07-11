{
  config,
  grafanaPort,
  hostInventory,
  lib,
  outputs,
  pkgs,
  blackboxHttpMtlsTlsConfig,
  prometheusMtlsTlsConfig,
}:
let
  lan = hostInventory.site.lan;
  nixosConfigNames = map hostInventory.toNixosConfigName hostInventory.nixosHostSpecs;
  httpsUrlFor = host: port: "https://${host}${lib.optionalString (port != 443) ":${toString port}"}/";
  beastHostConfig = outputs.nixosConfigurations.beast.config;
  publicWanHost = beastHostConfig.host.externalService.ddns.hostname;
  publicServiceCatalog = hostInventory.publicServices;
  publicWanProbeUrlFor = service: "https://${publicWanHost}${service.probePath}";
  publicDnsModuleNameFor = service: "dns_public_${service.id}";
  publicDnsCnameRegexpFor =
    service:
    "^${lib.escapeRegex "${service.publicHost}."}\\s+[0-9]+\\s+IN\\s+CNAME\\s+${lib.escapeRegex "${publicWanHost}."}$";
  srvarrHostConfig = outputs.nixosConfigurations.srvarr.config;
  srvarrPortFor =
    serviceId:
    {
      aurral = srvarrHostConfig.systemd.services.aurral.environment.PORT;
      audiobookshelf = srvarrHostConfig.services.audiobookshelf.port;
      bazarr = srvarrHostConfig.services.bazarr.listenPort;
      lidarr = srvarrHostConfig.services.lidarr.settings.server.port;
      prowlarr = srvarrHostConfig.services.prowlarr.settings.server.port;
      radarr = srvarrHostConfig.services.radarr.settings.server.port;
      sabnzbd = srvarrHostConfig.services.sabnzbd.settings.misc.port;
      shelfmark = srvarrHostConfig.services.shelfmark.environment.FLASK_PORT;
      sonarr = srvarrHostConfig.services.sonarr.settings.server.port;
      transmission = srvarrHostConfig.services.transmission.settings.rpc-port;
    }
    .${serviceId};
  ownerHostConfigFor =
    service:
    if service.owner == "fana" then config else outputs.nixosConfigurations.${service.owner}.config;
  ownerHttpsServicesFor = service: (ownerHostConfigFor service).host.internalHttps.services;
  httpsServiceFor =
    service:
    let
      httpsServices = ownerHttpsServicesFor service;
    in
    if
      builtins.hasAttr service.id httpsServices && (builtins.getAttr service.id httpsServices).enable
    then
      builtins.getAttr service.id httpsServices
    else
      null;
  mkOwnerServiceProbe =
    service: probePath:
    let
      httpsService = httpsServiceFor service;
    in
    if httpsService != null then
      {
        blackboxModule = if httpsService.mtls.enable then "http_service_mtls" else "http_service";
        probeUrl = "https://${httpsService.serverName}${probePath}";
        url = "https://${httpsService.serverName}/";
      }
    else if service.owner == "fana" then
      {
        probeUrl = "http://127.0.0.1:${toString grafanaPort}/${probePath}";
        url = "http://${service.displayHost}:3000/";
      }
    else if service.owner == "srvarr" then
      {
        probeUrl = "http://${service.probeHost}:${toString (srvarrPortFor service.id)}${probePath}";
        url = "http://${service.displayHost}:${toString (srvarrPortFor service.id)}/";
      }
    else
      throw "Blackbox service ${service.id} must expose enabled internal HTTPS";
  inventoryServiceCatalog = map (
    service:
    if service.scope == "external" then
      service
    else
      service // (mkOwnerServiceProbe service service.probePath)
  ) hostInventory.blackboxServices;
  backendProbeCatalog = map (
    service:
    let
      ownerProbe = mkOwnerServiceProbe service service.backendProbe.path;
    in
    service
    // ownerProbe
    // {
      blackboxModule =
        if service.backendProbe ? blackboxModule then
          service.backendProbe.blackboxModule
        else
          ownerProbe.blackboxModule or "http_service";
      backend_probe = service.backendProbe.name or "http";
      backend_probe_title = service.backendProbe.title or "Backend HTTP";
      scope = "backend";
    }
  ) (builtins.filter (service: service ? backendProbe) hostInventory.blackboxServices);
  usesHttpMtls = builtins.any (service: (service.blackboxModule or null) == "http_service_mtls") (
    inventoryServiceCatalog ++ backendProbeCatalog
  );
  proxmoxLabNodeNames = builtins.filter (
    name:
    (outputs.nixosConfigurations.${name}.config.host.isProxmox or false)
    && !(outputs.nixosConfigurations.${name}.config.host.isWork or false)
    && (outputs.nixosConfigurations.${name}.config.host.proxmox.apiCertificate.enable or false)
  ) nixosConfigNames;
  proxmoxServiceCatalog = map (
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
  ) proxmoxLabNodeNames;
  manualTlsServiceCatalog = [
    {
      id = "unifi";
      scope = "internal";
      title = "UniFi Console";
      probeUrl = "https://unifi.${lan.domain}/";
      url = "https://unifi.${lan.domain}/";
      tlsRotation = "manual";
    }
  ];
  serviceCatalog =
    inventoryServiceCatalog
    ++ [
      {
        id = "proxmox";
        scope = "internal";
        title = "Proxmox VE";
        probeUrl = "https://proxmox.${lan.domain}/";
        url = "https://proxmox.${lan.domain}/";
      }
    ]
    ++ proxmoxServiceCatalog
    ++ manualTlsServiceCatalog;
  dnsProbeTargets = [
    {
      resolver = "gateway";
      resolver_title = "gateway ${lan.gateway.address}";
      target = "${lan.gateway.address}:53";
    }
    {
      resolver = "google";
      resolver_title = "Google 8.8.8.8";
      target = "8.8.8.8:53";
    }
  ];
  publicDnsProbeTargets = [
    {
      resolver = "cloudflare";
      resolver_title = "Cloudflare 1.1.1.1";
      target = "1.1.1.1:53";
    }
    {
      resolver = "google";
      resolver_title = "Google 8.8.8.8";
      target = "8.8.8.8:53";
    }
  ];
  wanIcmpProbeTargets = [
    {
      probe = "gateway";
      probe_title = "Gateway ${lan.gateway.address}";
      target = lan.gateway.address;
    }
    {
      probe = "cloudflare";
      probe_title = "Cloudflare 1.1.1.1";
      target = "1.1.1.1";
    }
  ];
  wanTcpProbeTargets = [
    {
      probe = "gateway-dns";
      probe_title = "Gateway DNS ${lan.gateway.address}:53";
      target = "${lan.gateway.address}:53";
    }
    {
      probe = "cloudflare-https";
      probe_title = "Cloudflare 1.1.1.1:443";
      target = "1.1.1.1:443";
    }
  ];
  publicDnsBlackboxModules = builtins.listToAttrs (
    map (service: {
      name = publicDnsModuleNameFor service;
      value = {
        dns = {
          preferred_ip_protocol = "ip4";
          query_name = service.publicHost;
          query_type = "CNAME";
          transport_protocol = "udp";
          valid_rcodes = [ "NOERROR" ];
          validate_answer_rrs.fail_if_none_matches_regexp = [ (publicDnsCnameRegexpFor service) ];
        };
        prober = "dns";
        timeout = "5s";
      };
    }) publicServiceCatalog
  );
  baseBlackboxModules = import ../../../lib/prometheus-blackbox-modules.nix;
  blackboxModules =
    baseBlackboxModules
    // publicDnsBlackboxModules
    // lib.optionalAttrs usesHttpMtls {
      http_service_mtls = baseBlackboxModules.http_service // {
        http = baseBlackboxModules.http_service.http // {
          tls_config = blackboxHttpMtlsTlsConfig;
        };
      };
    };
  remoteBlackboxProbeSourceNames = builtins.filter (
    name:
    name != "fana"
    && outputs.nixosConfigurations.${name}.config.host.observability.client.blackbox.enable
  ) nixosConfigNames;
  remotePlainBlackboxProbeSourceNames = builtins.filter (
    name:
    !(outputs.nixosConfigurations.${name}.config.host.observability.client.blackbox.mtls.enable or false
    )
  ) remoteBlackboxProbeSourceNames;
  targetHostForNixosName =
    name: hostInventory.toNixosShortDnsName hostInventory.nixosHostSpecsByName.${name};
  mkRemoteBlackboxProbeSourceConfig =
    name:
    let
      hostConfig = outputs.nixosConfigurations.${name}.config;
      mtlsEndpoint = hostConfig.host.observability.client.prometheusMtlsEndpoints.blackbox;
    in
    {
      exporter = "${targetHostForNixosName name}:${toString mtlsEndpoint.port}";
      scheme = "https";
      source = hostConfig.services.avahi.hostName;
    };
  remoteBlackboxProbeSourceConfigs = map mkRemoteBlackboxProbeSourceConfig remoteBlackboxProbeSourceNames;
  blackboxProbeSourceConfigs = [
    {
      exporter = "127.0.0.1:${toString config.services.prometheus.exporters.blackbox.port}";
      scheme = "http";
      source = config.services.avahi.hostName;
    }
  ]
  ++ remoteBlackboxProbeSourceConfigs;
  mkBlackboxStaticConfigs =
    sources: probes:
    lib.concatMap (
      source:
      map (probe: {
        labels = {
          prober_address = source.exporter;
          prober_scheme = source.scheme;
          inherit (source) source;
          inherit (probe) probe probe_title;
        };
        targets = [ probe.target ];
      }) probes
    ) sources;
  publicDnsStaticConfigs = lib.concatMap (
    resolver:
    map (service: {
      labels = {
        scope = "external";
        service = service.id;
        service_title = service.title;
        public_host = service.publicHost;
        module = publicDnsModuleNameFor service;
        inherit (resolver) resolver resolver_title;
      };
      targets = [ resolver.target ];
    }) publicServiceCatalog
  ) publicDnsProbeTargets;
  mkServiceHttpStaticConfig = service: {
    labels = {
      module = service.blackboxModule or "http_service";
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
  blackboxProbeRelabelConfigs = [
    {
      source_labels = [ "__address__" ];
      target_label = "__param_target";
    }
    {
      source_labels = [ "__param_target" ];
      target_label = "target";
    }
    {
      separator = ":";
      source_labels = [
        "source"
        "probe"
      ];
      target_label = "instance";
    }
    {
      source_labels = [ "prober_address" ];
      target_label = "__address__";
    }
    {
      source_labels = [ "prober_scheme" ];
      target_label = "__scheme__";
    }
    {
      action = "labeldrop";
      regex = "prober_address|prober_scheme";
    }
  ];
in
{
  inherit usesHttpMtls;

  assertions = [
    {
      assertion = remotePlainBlackboxProbeSourceNames == [ ];
      message = "All remote blackbox probe sources must use mTLS. Offenders: ${lib.concatStringsSep ", " remotePlainBlackboxProbeSourceNames}";
    }
  ];

  exporterConfig = {
    enable = true;
    listenAddress = "127.0.0.1";
    configFile = (pkgs.formats.yaml { }).generate "blackbox.yml" {
      modules = blackboxModules;
    };
  };

  scrapeConfigs = [
    {
      job_name = "blackbox-arr";
      metrics_path = "/probe";
      static_configs = map mkServiceHttpStaticConfig serviceCatalog;
      relabel_configs = [
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
          replacement = "127.0.0.1:${toString config.services.prometheus.exporters.blackbox.port}";
          target_label = "__address__";
        }
        {
          action = "labeldrop";
          regex = "module";
        }
      ];
    }
    {
      job_name = "blackbox-backend";
      metrics_path = "/probe";
      static_configs = map mkServiceHttpStaticConfig backendProbeCatalog;
      relabel_configs = [
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
          replacement = "127.0.0.1:${toString config.services.prometheus.exporters.blackbox.port}";
          target_label = "__address__";
        }
        {
          action = "labeldrop";
          regex = "module";
        }
      ];
    }
    {
      job_name = "blackbox-public-wan";
      metrics_path = "/probe";
      params.module = [ "http_service" ];
      static_configs = map (service: {
        labels = {
          scope = "external";
          service = service.id;
          service_title = service.title;
          public_host = service.publicHost;
        };
        targets = [ (publicWanProbeUrlFor service) ];
      }) publicServiceCatalog;
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
          replacement = "127.0.0.1:${toString config.services.prometheus.exporters.blackbox.port}";
          target_label = "__address__";
        }
      ];
    }
    {
      job_name = "blackbox-dns";
      metrics_path = "/probe";
      params.module = [ "dns_udp" ];
      static_configs = map (resolver: {
        labels = {
          resolver = resolver.resolver;
          resolver_title = resolver.resolver_title;
        };
        targets = [ resolver.target ];
      }) dnsProbeTargets;
      relabel_configs = [
        {
          source_labels = [ "__address__" ];
          target_label = "__param_target";
        }
        {
          source_labels = [ "__param_target" ];
          target_label = "target";
        }
        {
          source_labels = [ "resolver" ];
          target_label = "instance";
        }
        {
          replacement = "127.0.0.1:${toString config.services.prometheus.exporters.blackbox.port}";
          target_label = "__address__";
        }
      ];
    }
    {
      job_name = "blackbox-public-dns";
      metrics_path = "/probe";
      static_configs = publicDnsStaticConfigs;
      relabel_configs = [
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
          separator = ":";
          source_labels = [
            "service"
            "resolver"
          ];
          target_label = "instance";
        }
        {
          replacement = "127.0.0.1:${toString config.services.prometheus.exporters.blackbox.port}";
          target_label = "__address__";
        }
        {
          action = "labeldrop";
          regex = "module";
        }
      ];
    }
    {
      job_name = "blackbox-icmp";
      metrics_path = "/probe";
      params.module = [ "icmp_ipv4" ];
      scrape_interval = "5s";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = mkBlackboxStaticConfigs blackboxProbeSourceConfigs wanIcmpProbeTargets;
      relabel_configs = blackboxProbeRelabelConfigs;
    }
    {
      job_name = "blackbox-tcp";
      metrics_path = "/probe";
      params.module = [ "tcp_connect_ipv4" ];
      scrape_interval = "5s";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = mkBlackboxStaticConfigs blackboxProbeSourceConfigs wanTcpProbeTargets;
      relabel_configs = blackboxProbeRelabelConfigs;
    }
  ];
}
