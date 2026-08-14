{
  config,
  lib,
  observabilityInventory,
  outputs,
  blackboxHttpMtlsTlsConfig,
  prometheusMtlsTlsConfig,
}:
let
  networkTargets = import ./network-targets.nix { inherit config; };
  inherit (networkTargets)
    dnsProbeTargets
    publicDnsProbeTargets
    wanIcmpProbeTargets
    wanTcpProbeTargets
    ;
  localHost = config.networking.hostName;
  configurations = outputs.nixosConfigurations // {
    ${localHost} = { inherit config; };
  };
  fleetServices = import ../../../../../_lib/fleet-web-services.nix {
    inherit config lib outputs;
  };
  ingressConfigurations = lib.filterAttrs (
    _: configuration:
    configuration.config.host.realm == config.host.realm
    && configuration.config.host.web.ingress != null
    && configuration.config.host.web.ingress.dynamicDns.enable
  ) configurations;
  ingressHosts = builtins.attrValues ingressConfigurations;
  publicWanHost =
    if ingressHosts == [ ] then
      ""
    else
      (lib.head ingressHosts).config.host.web.ingress.dynamicDns.hostname;
  publicServiceCatalog = map (contribution: {
    inherit (contribution) id;
    title = contribution.value.displayName;
    publicHost = contribution.value.public.hostName;
    probePath = contribution.value.health.frontend.path;
    availability = contribution.value.observability.availability;
  }) fleetServices.public;
  publicWanProbeUrlFor = service: "https://${publicWanHost}${service.probePath}";
  publicDnsModuleNameFor = service: "dns_public_${service.id}";
  publicDnsCnameRegexpFor =
    service:
    "^${lib.escapeRegex "${service.publicHost}."}\\s+[0-9]+\\s+IN\\s+CNAME\\s+${lib.escapeRegex "${publicWanHost}."}$";
  blackboxModuleFor =
    service: configuredModule:
    if configuredModule == "http_service" && service.internal.clientAuth == "mtls" then
      "http_service_mtls"
    else
      configuredModule;
  frontendProbeCatalog = map (
    contribution:
    let
      service = contribution.value;
      usePublic = service.public != null;
      baseUrl = if usePublic then service.public.url else service.internal.url;
    in
    {
      inherit (contribution) id;
      title = service.displayName;
      blackboxModule =
        if usePublic then
          service.health.frontend.module
        else
          blackboxModuleFor service service.health.frontend.module;
      probeUrl = "${baseUrl}${service.health.frontend.path}";
      scope = if usePublic then "external" else "internal";
      availability = service.observability.availability;
      url = "${baseUrl}/";
    }
  ) fleetServices.frontendProbes;
  backendProbeCatalog = map (
    contribution:
    let
      service = contribution.value;
      portSuffix = lib.optionalString (
        service.health.backend.port != 443
      ) ":${toString service.health.backend.port}";
    in
    {
      inherit (contribution) id;
      title = service.displayName;
      blackboxModule = blackboxModuleFor service service.health.backend.module;
      backend_probe = "http";
      backend_probe_title = service.health.backend.title;
      probeUrl = "https://${service.internal.serverName}${portSuffix}${service.health.backend.path}";
      scope = "backend";
      availability = service.observability.availability;
      url = "${service.internal.url}/";
    }
  ) fleetServices.backendProbes;
  serviceHttpProbeCatalog = frontendProbeCatalog ++ backendProbeCatalog;
  usesHttpMtls = builtins.any (service: (service.blackboxModule or null) == "http_service_mtls") (
    serviceHttpProbeCatalog
  );
  manualTlsServiceCatalog = [
    {
      id = "unifi";
      scope = "internal";
      title = "UniFi Console";
      probeUrl = "https://unifi.${config.host.network.lanDomain}/";
      url = "https://unifi.${config.host.network.lanDomain}/";
      tlsRotation = "manual";
    }
  ];
  serviceCatalog =
    frontendProbeCatalog
    ++ [
      {
        id = "proxmox";
        scope = "internal";
        title = "Proxmox VE";
        probeUrl = "https://proxmox.${config.host.network.lanDomain}/";
        url = "https://proxmox.${config.host.network.lanDomain}/";
      }
    ]
    ++ manualTlsServiceCatalog;
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
  httpServiceModule = config.host.observability.blackbox.baseModules.http_service;
  blackboxModules =
    publicDnsBlackboxModules
    // lib.optionalAttrs usesHttpMtls {
      http_service_mtls = httpServiceModule // {
        http = httpServiceModule.http // {
          tls_config = blackboxHttpMtlsTlsConfig;
        };
      };
    };
  remoteBlackboxProbeSourceConfigs = lib.filter (source: source != null) (
    map (inventory: inventory.blackbox) (
      builtins.attrValues (removeAttrs observabilityInventory.nixos [ localHost ])
    )
  );
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
          component = "blackbox";
          probe_family = "network";
          scrape_profile = "probe";
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
        component = "blackbox";
        probe_family = "dns";
        scrape_profile = "probe";
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
      availability = service.availability or "always";
      component = "blackbox";
      module = service.blackboxModule or "http_service";
      probe_family = "service";
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
  serviceHttpRelabelConfigs = [
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
  mkServiceHttpScrapeConfig = jobName: catalog: {
    job_name = jobName;
    metrics_path = "/probe";
    static_configs = map mkServiceHttpStaticConfig catalog;
    relabel_configs = serviceHttpRelabelConfigs;
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
  modules = blackboxModules;

  assertions = lib.optional (publicServiceCatalog != [ ]) {
    assertion = builtins.length ingressHosts == 1;
    message = "Public WAN probes require exactly one dynamic-DNS web ingress in the Prometheus realm.";
  };

  scrapeConfigs = [
    (mkServiceHttpScrapeConfig "blackbox-services" serviceCatalog)
    (mkServiceHttpScrapeConfig "blackbox-backend" backendProbeCatalog)
    {
      job_name = "blackbox-public-wan";
      metrics_path = "/probe";
      params.module = [ "http_service" ];
      static_configs = map (service: {
        labels = {
          availability = service.availability or "always";
          component = "blackbox";
          probe_family = "service";
          scrape_profile = "probe";
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
          component = "blackbox";
          probe_family = "dns";
          scrape_profile = "probe";
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
