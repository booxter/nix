{
  config,
  grafanaPort,
  hostInventory,
  lib,
  outputs,
  pkgs,
  prometheusMtlsTlsConfig,
}:
let
  lan = hostInventory.site.lan;
  nixosConfigNames = map hostInventory.toNixosConfigName hostInventory.nixosHostSpecs;
  httpsUrlFor = host: port: "https://${host}${lib.optionalString (port != 443) ":${toString port}"}/";
  localHttpsServices = config.host.internalHttps.services;
  srvarrHostConfig = outputs.nixosConfigurations.srvarr.config;
  srvarrHttpsServices = srvarrHostConfig.host.internalHttps.services;
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
  httpsServiceFor =
    service:
    if
      builtins.hasAttr service.id srvarrHttpsServices
      && (builtins.getAttr service.id srvarrHttpsServices).enable
    then
      builtins.getAttr service.id srvarrHttpsServices
    else
      null;
  localHttpsServiceFor =
    service:
    if
      builtins.hasAttr service.id localHttpsServices
      && (builtins.getAttr service.id localHttpsServices).enable
    then
      builtins.getAttr service.id localHttpsServices
    else
      null;
  inventoryServiceCatalog = map (
    service:
    let
      httpsService = httpsServiceFor service;
      localHttpsService = localHttpsServiceFor service;
    in
    if service.scope == "external" then
      service
    else if service.owner == "fana" && localHttpsService != null then
      service
      // {
        probeUrl = "https://${localHttpsService.serverName}${service.probePath}";
        url = "https://${localHttpsService.serverName}/";
      }
    else if service.owner == "fana" then
      service
      // {
        probeUrl = "http://127.0.0.1:${toString grafanaPort}/${service.probePath}";
        url = "http://${service.displayHost}:3000/";
      }
    else if httpsService != null then
      service
      // {
        probeUrl = "https://${httpsService.serverName}${service.probePath}";
        url = "https://${httpsService.serverName}/";
      }
    else
      service
      // {
        probeUrl = "http://${service.probeHost}:${toString (srvarrPortFor service.id)}${service.probePath}";
        url = "http://${service.displayHost}:${toString (srvarrPortFor service.id)}/";
      }
  ) hostInventory.services;
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
  serviceCatalog = inventoryServiceCatalog ++ proxmoxServiceCatalog;
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
  blackboxModules = import ../../../lib/prometheus-blackbox-modules.nix;
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
  mkRemoteBlackboxProbeSourceConfig =
    name:
    let
      hostConfig = outputs.nixosConfigurations.${name}.config;
      mtlsEndpoint = hostConfig.host.observability.client.prometheusMtlsEndpoints.blackbox;
    in
    {
      exporter = "${hostConfig.host.dnsName}:${toString mtlsEndpoint.port}";
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
      params.module = [ "http_service" ];
      static_configs = map (service: {
        labels = {
          scope = service.scope;
          service = service.id;
          service_title = service.title;
        };
        targets = [ service.probeUrl ];
      }) serviceCatalog;
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
