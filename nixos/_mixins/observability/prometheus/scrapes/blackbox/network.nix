{
  config,
  hostInventory,
  lib,
  outputs,
  prometheusMtlsTlsConfig,
}:
let
  lan = hostInventory.site.lan;
  realmName = config.host.realm;
  realmObservability = hostInventory.realms.${realmName}.services.observability;
  blackboxServerHost = hostInventory.serviceHost hostInventory.servicesById.prometheus;
  sourceHostNames = realmObservability.blackbox.sourceHosts;
  blackboxAddress = "127.0.0.1:${toString config.services.prometheus.exporters.blackbox.port}";

  publicServices = hostInventory.publicServices;
  beastConfig = outputs.nixosConfigurations.beast.config;
  publicWanHost = beastConfig.host.externalService.ddns.hostname;
  publicDnsModuleNameFor = service: "dns_public_${service.id}";
  publicDnsCnameRegexpFor =
    service:
    "^${lib.escapeRegex "${service.publicHost}."}\\s+[0-9]+\\s+IN\\s+CNAME\\s+${lib.escapeRegex "${publicWanHost}."}$";
  modules = builtins.listToAttrs (
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
    }) publicServices
  );

  missingSourceHostNames = builtins.filter (
    name: !builtins.hasAttr name hostInventory.nixosHosts
  ) sourceHostNames;
  crossRealmSourceHostNames = builtins.filter (
    name:
    builtins.hasAttr name hostInventory.nixosHosts
    && hostInventory.nixosHosts.${name}.realm != realmName
  ) sourceHostNames;
  remoteSourceHostNames = builtins.filter (name: name != blackboxServerHost) sourceHostNames;
  mkRemoteSource =
    name:
    let
      hostConfig = outputs.nixosConfigurations.${name}.config;
      endpoint = hostConfig.host.observability.metricsEndpoints.blackbox;
    in
    {
      exporter = "${name}:${toString endpoint.port}";
      scheme = "https";
      source = hostConfig.services.avahi.hostName;
    };
  sources = [
    {
      exporter = blackboxAddress;
      scheme = "http";
      source = config.services.avahi.hostName;
    }
  ]
  ++ map mkRemoteSource remoteSourceHostNames;

  dnsTargets = [
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
  publicDnsTargets = [
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
  icmpTargets = [
    {
      probe = "gateway";
      probe_protocol = "icmp";
      probe_title = "Gateway ${lan.gateway.address}";
      target = lan.gateway.address;
    }
    {
      probe = "cloudflare";
      probe_protocol = "icmp";
      probe_title = "Cloudflare 1.1.1.1";
      target = "1.1.1.1";
    }
  ];
  tcpTargets = [
    {
      probe = "gateway-dns";
      probe_protocol = "tcp";
      probe_title = "Gateway DNS ${lan.gateway.address}:53";
      target = "${lan.gateway.address}:53";
    }
    {
      probe = "cloudflare-https";
      probe_protocol = "tcp";
      probe_title = "Cloudflare 1.1.1.1:443";
      target = "1.1.1.1:443";
    }
  ];

  networkStaticConfigs =
    probes:
    lib.concatMap (
      source:
      map (probe: {
        labels = {
          availability = "always";
          component = "blackbox";
          probe_family = "network";
          probe_role = "reachability";
          prober_address = source.exporter;
          prober_scheme = source.scheme;
          realm = realmName;
          scrape_profile = "probe";
          inherit (source) source;
          inherit (probe) probe probe_protocol probe_title;
        };
        targets = [ probe.target ];
      }) probes
    ) sources;
  networkRelabelConfigs = [
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
      assertion = config.networking.hostName == blackboxServerHost;
      message = "Blackbox probe collection must run on realm '${realmName}' observability server '${blackboxServerHost}'.";
    }
    {
      assertion = builtins.elem blackboxServerHost sourceHostNames;
      message = "Realm '${realmName}' blackbox source hosts must include observability server '${blackboxServerHost}'.";
    }
    {
      assertion = missingSourceHostNames == [ ];
      message = "Realm '${realmName}' blackbox source hosts do not exist: ${lib.concatStringsSep ", " missingSourceHostNames}";
    }
    {
      assertion = crossRealmSourceHostNames == [ ];
      message = "Realm '${realmName}' blackbox source hosts belong to another realm: ${lib.concatStringsSep ", " crossRealmSourceHostNames}";
    }
  ];

  inherit modules;

  scrapeConfigs = [
    {
      job_name = "blackbox-dns";
      metrics_path = "/probe";
      params.module = [ "dns_udp" ];
      static_configs = map (resolver: {
        labels = {
          availability = "always";
          component = "blackbox";
          probe_family = "dns";
          probe_protocol = "dns";
          probe_role = "resolver";
          realm = realmName;
          resolver = resolver.resolver;
          resolver_title = resolver.resolver_title;
          scrape_profile = "probe";
          source = config.services.avahi.hostName;
        };
        targets = [ resolver.target ];
      }) dnsTargets;
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
          replacement = blackboxAddress;
          target_label = "__address__";
        }
      ];
    }
    {
      job_name = "blackbox-public-dns";
      metrics_path = "/probe";
      static_configs = lib.concatMap (
        resolver:
        map (service: {
          labels = {
            availability = service.observability.availability or "always";
            component = "blackbox";
            module = publicDnsModuleNameFor service;
            probe_family = "dns";
            probe_protocol = "dns";
            probe_role = "public-service";
            public_host = service.publicHost;
            realm = realmName;
            scrape_profile = "probe";
            scope = "external";
            service = service.id;
            service_title = service.title;
            inherit (resolver) resolver resolver_title;
          };
          targets = [ resolver.target ];
        }) publicServices
      ) publicDnsTargets;
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
          replacement = blackboxAddress;
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
      static_configs = networkStaticConfigs icmpTargets;
      relabel_configs = networkRelabelConfigs;
    }
    {
      job_name = "blackbox-tcp";
      metrics_path = "/probe";
      params.module = [ "tcp_connect_ipv4" ];
      scrape_interval = "5s";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = networkStaticConfigs tcpTargets;
      relabel_configs = networkRelabelConfigs;
    }
  ];
}
