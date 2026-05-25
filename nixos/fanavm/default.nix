{
  config,
  lib,
  hostInventory,
  outputs,
  pkgs,
  ...
}:
let
  beastSpec = hostInventory.nixosHostSpecsByName.beast;
  frameSpec = hostInventory.nixosHostSpecsByName.frame;
  internalPkiRootCaPath = ../../common/_mixins/internal-pki/home-internal-pki-root-ca.crt;
  lan = hostInventory.site.lan;
  pi5Spec = hostInventory.nixosHostSpecsByName.pi5;
  prx1Spec = hostInventory.nixosHostSpecsByName."prx1-lab";
  localHttpsServices = config.host.internalHttps.services;
  srvarrPorts = {
    aurral = outputs.nixosConfigurations.prox-srvarrvm.config.systemd.services.aurral.environment.PORT;
    audiobookshelf = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.audiobookshelf.port;
    bazarr = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.bazarr.port;
    lidarr = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.lidarr.port;
    prowlarr = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.prowlarr.port;
    radarr = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.radarr.port;
    sabnzbd = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.sabnzbd.guiPort;
    shelfmark = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.shelfmark.port;
    sonarr = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.sonarr.port;
    transmission = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.transmission.uiPort;
  };
  srvarrHostConfig = outputs.nixosConfigurations.prox-srvarrvm.config;
  srvarrHttpsServices = srvarrHostConfig.host.internalHttps.services;
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
  serviceCatalog = map (
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
        probeUrl = "http://${service.probeHost}:${toString srvarrPorts.${service.id}}${service.probePath}";
        url = "http://${service.displayHost}:${toString srvarrPorts.${service.id}}/";
      }
  ) hostInventory.services;
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
  blackboxModules = import ../../lib/prometheus-blackbox-modules.nix;
  grafanaPort = 3000;
  prometheusPort = 9090;
  lokiPort = 3100;
  nutExporterPort = 9199;
  beastHostConfig = outputs.nixosConfigurations.beast.config;
  beastPrometheusEndpoints = beastHostConfig.host.observability.client.prometheusMtlsEndpoints;
  sabnzbdHostConfig = srvarrHostConfig;
  sabnzbdEndpoint = sabnzbdHostConfig.host.observability.client.prometheusMtlsEndpoints.sabnzbd;
  prometheusMtlsTlsConfig = {
    ca_file = toString internalPkiRootCaPath;
    cert_file = config.sops.secrets.prometheusScrapeNodeClientCrt.path;
    key_file = config.sops.secrets.prometheusScrapeNodeClientKey.path;
  };
  vikunjaHostConfig = outputs.nixosConfigurations.prox-orgvm.config;
  vikunjaHost = vikunjaHostConfig.host.dnsName;
  vikunjaEndpoint = vikunjaHostConfig.host.observability.client.prometheusMtlsEndpoints.vikunja;
  retentionDays = 365;
  retentionHours = retentionDays * 24;
  prometheusRetention = "${toString retentionDays}d";
  lokiRetention = "${toString retentionHours}h";
  grafanaPrometheusUid = "PBFA97CFB590B2093";
  grafanaLokiUid = "P8E80F9AEF21F6940";
  nutExporterVariables = lib.concatStringsSep "," [
    "battery.charge"
    "battery.charge.low"
    "battery.runtime"
    "battery.runtime.low"
    "input.voltage"
    "input.voltage.nominal"
    "ups.load"
    "ups.status"
  ];
  isVirtualNodeName = name: lib.hasPrefix "prox-" name && lib.hasSuffix "vm" name;
  hostClassForName = name: if isVirtualNodeName name then "virtual" else "hardware";
  mkRemoteNixosNodeTargetConfig =
    name:
    let
      hostConfig = outputs.nixosConfigurations.${name}.config;
    in
    {
      labels = {
        host_network_charts = lib.boolToString (!hostConfig.host.isProxmox);
        host_network_source = if hostConfig.host.isProxmox then "classified" else "node";
        host_class = hostClassForName name;
        host_virtual = lib.boolToString (isVirtualNodeName name);
        instance = hostConfig.host.dnsName;
      };
      targets = [ "${hostConfig.host.dnsName}:9100" ];
    };
  nixosNodeExporterTargetNames = builtins.filter (
    name:
    !(lib.hasPrefix "local-" name)
    && name != "prox-deskvm"
    && name != "prox-fanavm"
    && (outputs.nixosConfigurations.${name}.config.host.observability.client.enable or false)
    && !(outputs.nixosConfigurations.${name}.config.host.isWork or false)
  ) (builtins.attrNames outputs.nixosConfigurations);
  remoteNixosNonMtlsNodeTargetNames = builtins.filter (
    name:
    !(outputs.nixosConfigurations.${name}.config.host.observability.client.nodeExporter.mtls.enable
      or false
    )
  ) nixosNodeExporterTargetNames;
  remoteNixosNodeTargetConfigs = map mkRemoteNixosNodeTargetConfig nixosNodeExporterTargetNames;
  mkRemoteDarwinNodeTargetConfig =
    name:
    let
      hostConfig = outputs.darwinConfigurations.${name}.config;
    in
    {
      labels = {
        host_network_charts = "true";
        host_network_source = "node";
        host_class = "hardware";
        host_virtual = "false";
        instance = hostConfig.host.dnsName;
      };
      targets = [ "${hostConfig.host.dnsName}:9100" ];
    };
  darwinNodeExporterTargetNames = builtins.filter (
    name:
    (outputs.darwinConfigurations.${name}.config.host.observability.client.enable or false)
    && !(outputs.darwinConfigurations.${name}.config.host.isWork or false)
  ) (builtins.attrNames outputs.darwinConfigurations);
  remoteDarwinNonMtlsNodeTargetNames = builtins.filter (
    name:
    !(outputs.darwinConfigurations.${name}.config.host.observability.client.nodeExporter.mtls.enable
      or false
    )
  ) darwinNodeExporterTargetNames;
  remoteDarwinNodeTargetConfigs = map mkRemoteDarwinNodeTargetConfig darwinNodeExporterTargetNames;
  remoteNodeTargetConfigs = remoteNixosNodeTargetConfigs ++ remoteDarwinNodeTargetConfigs;
  remoteBlackboxProbeSourceNames = builtins.filter (
    name:
    !(lib.hasPrefix "local-" name)
    && name != "prox-fanavm"
    && outputs.nixosConfigurations.${name}.config.host.observability.client.blackbox.enable
  ) (builtins.attrNames outputs.nixosConfigurations);
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
  mkGrafanaPromRule =
    {
      uid,
      title,
      expr,
      comparator,
      threshold,
      forDuration,
      annotations,
      labels ? { },
      noDataState ? "NoData",
    }:
    {
      inherit
        uid
        title
        annotations
        labels
        noDataState
        ;
      condition = "B";
      data = [
        {
          refId = "A";
          relativeTimeRange = {
            from = 600;
            to = 0;
          };
          datasourceUid = grafanaPrometheusUid;
          model = {
            datasource = {
              type = "prometheus";
              uid = grafanaPrometheusUid;
            };
            editorMode = "code";
            expr = expr;
            instant = true;
            intervalMs = 1000;
            legendFormat = "__auto";
            maxDataPoints = 43200;
            range = false;
            refId = "A";
          };
        }
        {
          refId = "B";
          relativeTimeRange = {
            from = 0;
            to = 0;
          };
          datasourceUid = "__expr__";
          model = {
            conditions = [
              {
                evaluator = {
                  params = [ threshold ];
                  type = comparator;
                };
                operator = {
                  type = "and";
                };
                query = {
                  params = [ "A" ];
                };
                reducer = {
                  type = "last";
                };
                type = "query";
              }
            ];
            datasource = {
              type = "__expr__";
              uid = "__expr__";
            };
            expression = "A";
            intervalMs = 1000;
            maxDataPoints = 43200;
            refId = "B";
            type = "classic_conditions";
          };
        }
      ];
      execErrState = "Alerting";
      "for" = forDuration;
    };
in
{
  imports = [ ./monitoring ];

  assertions = [
    {
      assertion = remoteNixosNonMtlsNodeTargetNames == [ ];
      message = "All non-local NixOS Prometheus node scrape targets must use mTLS. Offenders: ${lib.concatStringsSep ", " remoteNixosNonMtlsNodeTargetNames}";
    }
    {
      assertion = remoteDarwinNonMtlsNodeTargetNames == [ ];
      message = "All Darwin Prometheus node scrape targets must use mTLS. Offenders: ${lib.concatStringsSep ", " remoteDarwinNonMtlsNodeTargetNames}";
    }
    {
      assertion = remotePlainBlackboxProbeSourceNames == [ ];
      message = "All remote blackbox probe sources must use mTLS. Offenders: ${lib.concatStringsSep ", " remotePlainBlackboxProbeSourceNames}";
    }
  ];

  sops = {
    defaultSopsFile = ../../secrets/prox-fanavm.yaml;
  };

  sops.secrets.grafanaSecretKey = {
    key = "grafana/secret_key";
    owner = "grafana";
    group = "grafana";
    mode = "0400";
  };
  sops.secrets.grafanaAdminPassword = {
    key = "grafana/admin_password";
    owner = "grafana";
    group = "grafana";
    mode = "0400";
  };
  sops.secrets.grafanaAlertingTelegramBotToken = {
    key = "grafana/alerting/telegram/bot_token";
    owner = "grafana";
    group = "grafana";
    mode = "0400";
    restartUnits = [
      "alertmanager.service"
      "grafana.service"
    ];
  };
  sops.secrets.grafanaAlertingTelegramChatId = {
    key = "grafana/alerting/telegram/chat_id";
    owner = "grafana";
    group = "grafana";
    mode = "0400";
    restartUnits = [
      "alertmanager.service"
      "grafana.service"
    ];
  };
  sops.secrets.prometheusScrapeNodeClientCrt = {
    key = "prometheus/scrape_node/client_crt";
    owner = "prometheus";
    group = "prometheus";
    mode = "0400";
    restartUnits = [ "prometheus.service" ];
  };
  sops.secrets.prometheusScrapeNodeClientKey = {
    key = "prometheus/scrape_node/client_key";
    owner = "prometheus";
    group = "prometheus";
    mode = "0400";
    restartUnits = [ "prometheus.service" ];
  };
  sops.templates."grafana-alerting-contact-points.yaml" = {
    owner = "grafana";
    group = "grafana";
    mode = "0400";
    content = ''
      apiVersion: 1
      contactPoints:
        - orgId: 1
          name: telegram-home
          receivers:
            - uid: telegram-home
              type: telegram
              disableResolveMessage: false
              settings:
                bottoken: "${config.sops.placeholder.grafanaAlertingTelegramBotToken}"
                chatid: "${config.sops.placeholder.grafanaAlertingTelegramChatId}"
                uploadImage: false
    '';
    restartUnits = [ "grafana.service" ];
  };

  # Grafana provides the UI for dashboards and exploring metrics and logs.
  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "127.0.0.1";
        http_port = grafanaPort;
        domain = "grafana.${lan.domain}";
        root_url = "https://grafana.${lan.domain}/";
      };
      security = {
        admin_user = "admin";
        admin_password = "$__file{${config.sops.secrets.grafanaAdminPassword.path}}";
        secret_key = "$__file{${config.sops.secrets.grafanaSecretKey.path}}";
      };
      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
        check_for_plugin_updates = false;
      };
      plugins = {
        preinstall_disabled = true;
      };
    };
    provision = {
      enable = true;
      datasources.settings = {
        apiVersion = 1;
        datasources = [
          {
            name = "Prometheus";
            uid = grafanaPrometheusUid;
            type = "prometheus";
            access = "proxy";
            url = "http://127.0.0.1:${toString prometheusPort}";
            isDefault = true;
            editable = false;
          }
          {
            name = "Loki";
            uid = grafanaLokiUid;
            type = "loki";
            access = "proxy";
            url = "http://127.0.0.1:${toString lokiPort}";
            editable = false;
          }
        ];
      };
      dashboards.settings = {
        apiVersion = 1;
        providers = [
          {
            name = "fana";
            folder = "Fana";
            type = "file";
            disableDeletion = false;
            editable = false;
            updateIntervalSeconds = 30;
            options.path = ./grafana/dashboards;
          }
        ];
      };
      alerting.contactPoints.path = config.sops.templates."grafana-alerting-contact-points.yaml".path;
      alerting.policies.settings = {
        apiVersion = 1;
        policies = [
          {
            orgId = 1;
            receiver = "telegram-home";
            group_by = [ "alertname" ];
            group_wait = "5s";
            group_interval = "5m";
            repeat_interval = "12h";
          }
        ];
      };
      alerting.rules.settings = {
        apiVersion = 1;
        deleteRules = [
          {
            orgId = 1;
            uid = "dns_upstream_failures";
          }
          {
            orgId = 1;
            uid = "dns_probe_down";
          }
        ];
        groups = [
          {
            orgId = 1;
            name = "thermal-health";
            folder = "Fana";
            interval = "30s";
            rules = [
              (mkGrafanaPromRule {
                uid = "thermal_cpu_hot";
                title = "CPU Temperature High";
                expr = "max by(instance) ((node_thermal_zone_temp{job=~\"node|node-mtls\",host_class=\"hardware\",type=~\"cpu-thermal|x86_pkg_temp\"} or node_hwmon_temp_celsius{job=~\"node|node-mtls\",host_class=\"hardware\",chip=~\"platform_coretemp_0|pci0000:00_0000:00:18_3\",sensor=\"temp1\"}) or host_observability_darwin_temperature_group_max_celsius{job=~\"node|node-mtls\",host_class=\"hardware\",group=\"cpu\"})";
                comparator = "gt";
                threshold = 85;
                forDuration = "10m";
                annotations = {
                  summary = "CPU temperature high on {{ $labels.instance }}";
                  description = "{{ $labels.instance }} has sustained CPU/package temperature above 85C for 10 minutes.";
                };
                labels = {
                  severity = "warning";
                  category = "thermal";
                };
              })
              (mkGrafanaPromRule {
                uid = "thermal_storage_hot";
                title = "Storage Temperature High";
                expr = "max by(instance) (node_hwmon_temp_celsius{job=~\"node|node-mtls\",host_class=\"hardware\",chip=~\"nvme_.*\",sensor=\"temp1\"} or host_observability_hba_temperature_celsius{job=~\"node|node-mtls\",host_class=\"hardware\",sensor=\"roc\"} or host_observability_darwin_temperature_group_max_celsius{job=~\"node|node-mtls\",host_class=\"hardware\",group=\"storage\"})";
                comparator = "gt";
                threshold = 75;
                forDuration = "10m";
                annotations = {
                  summary = "Storage temperature high on {{ $labels.instance }}";
                  description = "{{ $labels.instance }} has sustained storage temperature above 75C for 10 minutes.";
                };
                labels = {
                  severity = "warning";
                  category = "thermal";
                };
              })
              (mkGrafanaPromRule {
                uid = "thermal_hba_export_failed";
                title = "HBA Thermal Export Failed";
                expr = "host_observability_hba_collect_success{job=~\"node|node-mtls\",host_class=\"hardware\"}";
                comparator = "lt";
                threshold = 1;
                forDuration = "10m";
                annotations = {
                  summary = "HBA thermal export failed on {{ $labels.instance }} (controller {{ $labels.controller }})";
                  description = "The StorCLI-based HBA collector has not been exporting successfully for controller {{ $labels.controller }} on {{ $labels.instance }} for 10 minutes.";
                };
                labels = {
                  severity = "warning";
                  category = "thermal";
                };
              })
              (mkGrafanaPromRule {
                uid = "thermal_hdd_hot";
                title = "HDD Temperature High";
                expr = "smartctl_device_temperature{instance=\"beast\",temperature_type=\"current\",device=~\"sd[a-z]+\"}";
                comparator = "gt";
                threshold = 50;
                forDuration = "30m";
                annotations = {
                  summary = "HDD temperature high on beast";
                  description = "Drive {{ $labels.device }} on beast has sustained temperature above 50C for 30 minutes.";
                };
                labels = {
                  severity = "warning";
                  category = "thermal";
                };
              })
              (mkGrafanaPromRule {
                uid = "darwin_ismc_export_failed";
                title = "Darwin Thermal Export Failed";
                expr = "host_observability_darwin_ismc_collect_success{job=~\"node|node-mtls\",host_class=\"hardware\"}";
                comparator = "lt";
                threshold = 1;
                forDuration = "10m";
                annotations = {
                  summary = "Darwin thermal export failed on {{ $labels.instance }}";
                  description = "The iSMC-based thermal collector has not been exporting successfully on {{ $labels.instance }} for 10 minutes.";
                };
                labels = {
                  severity = "warning";
                  category = "thermal";
                };
              })
            ];
          }
          {
            orgId = 1;
            name = "ups-health";
            folder = "Fana";
            interval = "30s";
            rules = [
              (mkGrafanaPromRule {
                uid = "ups_exporter_down";
                title = "UPS Exporter Down";
                expr = "up{job=~\"nut-.*\"}";
                comparator = "lt";
                threshold = 1;
                forDuration = "5m";
                annotations = {
                  summary = "UPS exporter down: {{ $labels.job }}";
                  description = "Prometheus has been unable to scrape {{ $labels.job }} for 5 minutes.";
                };
                labels = {
                  severity = "warning";
                  category = "ups";
                };
              })
              (mkGrafanaPromRule {
                uid = "ups_on_battery";
                title = "UPS On Battery";
                expr = "network_ups_tools_ups_status{job=~\"nut-.*\",ups=~\".+\",flag=\"OB\"}";
                comparator = "gt";
                threshold = 0;
                forDuration = "2m";
                annotations = {
                  summary = "UPS on battery: {{ $labels.ups }}";
                  description = "UPS {{ $labels.ups }} on {{ $labels.job }} has been on battery for 2 minutes.";
                };
                labels = {
                  severity = "critical";
                  category = "ups";
                };
              })
              (mkGrafanaPromRule {
                uid = "ups_low_battery";
                title = "UPS Low Battery";
                expr = "network_ups_tools_ups_status{job=~\"nut-.*\",ups=~\".+\",flag=\"LB\"}";
                comparator = "gt";
                threshold = 0;
                forDuration = "1m";
                annotations = {
                  summary = "UPS low battery: {{ $labels.ups }}";
                  description = "UPS {{ $labels.ups }} is reporting low battery.";
                };
                labels = {
                  severity = "critical";
                  category = "ups";
                };
              })
            ];
          }
          {
            orgId = 1;
            name = "pki-health";
            folder = "Fana";
            interval = "30s";
            rules = [
              (mkGrafanaPromRule {
                uid = "internal_pki_cert_missing";
                title = "Internal PKI Cert Missing";
                expr = "host_observability_pki_cert_parse_success{job=\"node-mtls\",instance=\"prox-pkivm\"}";
                comparator = "lt";
                threshold = 1;
                forDuration = "10m";
                annotations = {
                  summary = "Managed PKI cert missing: {{ $labels.host }} / {{ $labels.cert_name }}";
                  description = "The managed certificate {{ $labels.cert_name }} for {{ $labels.host }} ({{ $labels.category }}) is expected but missing or unparsable in the repo-managed PKI inventory.";
                };
                labels = {
                  severity = "critical";
                  category = "pki";
                };
              })
              (mkGrafanaPromRule {
                uid = "internal_pki_cert_expiry_warning";
                title = "Internal PKI Cert Expiring Soon";
                expr = "host_observability_pki_cert_days_remaining{job=\"node-mtls\",instance=\"prox-pkivm\"}";
                comparator = "lt";
                threshold = 30;
                forDuration = "30m";
                annotations = {
                  summary = "Managed PKI cert expiring soon: {{ $labels.host }} / {{ $labels.cert_name }}";
                  description = "The managed certificate {{ $labels.cert_name }} for {{ $labels.host }} ({{ $labels.category }}) has less than 30 days remaining.";
                };
                labels = {
                  severity = "warning";
                  category = "pki";
                };
              })
              (mkGrafanaPromRule {
                uid = "internal_pki_cert_expiry_critical";
                title = "Internal PKI Cert Expiring Critically Soon";
                expr = "host_observability_pki_cert_days_remaining{job=\"node-mtls\",instance=\"prox-pkivm\"}";
                comparator = "lt";
                threshold = 14;
                forDuration = "30m";
                annotations = {
                  summary = "Managed PKI cert expiring critically soon: {{ $labels.host }} / {{ $labels.cert_name }}";
                  description = "The managed certificate {{ $labels.cert_name }} for {{ $labels.host }} ({{ $labels.category }}) has less than 14 days remaining.";
                };
                labels = {
                  severity = "critical";
                  category = "pki";
                };
              })
              (mkGrafanaPromRule {
                uid = "public_tls_cert_expiry_warning";
                title = "Public TLS Cert Expiring Soon";
                expr = "((probe_ssl_earliest_cert_expiry{job=\"blackbox-arr\",scope=\"external\"} - time()) / 86400)";
                comparator = "lt";
                threshold = 30;
                forDuration = "30m";
                annotations = {
                  summary = "Public TLS cert expiring soon: {{ $labels.instance }}";
                  description = "The public HTTPS endpoint {{ $labels.instance }} has less than 30 days remaining on its leaf certificate.";
                };
                labels = {
                  severity = "warning";
                  category = "pki";
                };
              })
              (mkGrafanaPromRule {
                uid = "public_tls_cert_expiry_critical";
                title = "Public TLS Cert Expiring Critically Soon";
                expr = "((probe_ssl_earliest_cert_expiry{job=\"blackbox-arr\",scope=\"external\"} - time()) / 86400)";
                comparator = "lt";
                threshold = 14;
                forDuration = "30m";
                annotations = {
                  summary = "Public TLS cert expiring critically soon: {{ $labels.instance }}";
                  description = "The public HTTPS endpoint {{ $labels.instance }} has less than 14 days remaining on its leaf certificate.";
                };
                labels = {
                  severity = "critical";
                  category = "pki";
                };
              })
              (mkGrafanaPromRule {
                uid = "pki_rotation_controller_failed";
                title = "PKI Rotation Controller Failed";
                expr = "host_observability_pki_rotation_last_success{job=\"node-mtls\",instance=\"prox-pkivm\"}";
                comparator = "lt";
                threshold = 1;
                forDuration = "2h";
                annotations = {
                  summary = "PKI rotation controller failed on prox-pkivm";
                  description = "The most recent scheduled PKI rotation controller run on prox-pkivm did not complete successfully.";
                };
                labels = {
                  severity = "warning";
                  category = "pki";
                };
                noDataState = "OK";
              })
              (mkGrafanaPromRule {
                uid = "pki_rotation_controller_stale";
                title = "PKI Rotation Controller Stale";
                expr = "((time() - host_observability_pki_rotation_last_run_timestamp_seconds{job=\"node-mtls\",instance=\"prox-pkivm\"}) / 3600)";
                comparator = "gt";
                threshold = 36;
                forDuration = "2h";
                annotations = {
                  summary = "PKI rotation controller stale on prox-pkivm";
                  description = "The scheduled PKI rotation controller on prox-pkivm has not completed a run for more than 36 hours.";
                };
                labels = {
                  severity = "warning";
                  category = "pki";
                };
                noDataState = "OK";
              })
            ];
          }
        ];
      };
    };
  };

  host.internalHttps.services.grafana = {
    enable = true;
    upstream = "http://127.0.0.1:${toString grafanaPort}";
  };

  host.internalHttps.services.loki = {
    enable = true;
    upstream = "http://127.0.0.1:${toString lokiPort}";
    mtls.enable = true;
    locationExtraConfig = ''
      client_max_body_size 0;
      proxy_request_buffering off;
    '';
  };

  systemd.services.grafana = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };
  systemd.services.prometheus = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };

  systemd.services.prometheus-nut-exporter = {
    description = "Prometheus exporter for NUT UPS servers";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.prometheus-nut-exporter}/bin/nut_exporter --web.listen-address=127.0.0.1:${toString nutExporterPort} --nut.vars_enable=${nutExporterVariables}";
      DynamicUser = true;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      Restart = "always";
      RestartSec = "5s";
    };
  };

  # Prometheus scrapes and stores time-series metrics from this machine.
  services.prometheus = {
    enable = true;
    checkConfig = "syntax-only";
    listenAddress = "127.0.0.1";
    port = prometheusPort;
    retentionTime = prometheusRetention;
    scrapeConfigs = [
      {
        job_name = "prometheus";
        static_configs = [
          {
            targets = [ "127.0.0.1:${toString prometheusPort}" ];
          }
        ];
      }
      {
        job_name = "node";
        static_configs = [
          {
            targets = [
              "127.0.0.1:${toString config.services.prometheus.exporters.node.port}"
            ];
            labels = {
              host_network_charts = "true";
              host_network_source = "node";
              host_class = hostClassForName config.networking.hostName;
              host_virtual = lib.boolToString (isVirtualNodeName config.networking.hostName);
              instance = config.host.dnsName;
            };
          }
        ];
      }
      {
        job_name = "node-mtls";
        scheme = "https";
        tls_config = prometheusMtlsTlsConfig;
        static_configs = remoteNodeTargetConfigs;
      }
      {
        job_name = "nut-prx1";
        metrics_path = "/ups_metrics";
        params = {
          # Use the stable LAN DNS hostname rather than .local/mDNS.
          server = [ (prx1Spec.dnsName or prx1Spec.name) ];
          ups = [ (hostInventory.toUpsName prx1Spec.name) ];
        };
        static_configs = [
          {
            targets = [ "127.0.0.1:${toString nutExporterPort}" ];
          }
        ];
        relabel_configs = [
          {
            source_labels = [ "__param_server" ];
            target_label = "instance";
          }
          {
            source_labels = [ "__param_server" ];
            target_label = "ups_server";
          }
          {
            source_labels = [ "__param_ups" ];
            target_label = "ups";
          }
        ];
      }
      {
        job_name = "nut-pi5";
        metrics_path = "/ups_metrics";
        params = {
          # Use the stable LAN DNS hostname rather than .local/mDNS.
          server = [ (pi5Spec.dnsName or pi5Spec.name) ];
          ups = [ (hostInventory.toUpsName pi5Spec.name) ];
        };
        static_configs = [
          {
            targets = [ "127.0.0.1:${toString nutExporterPort}" ];
          }
        ];
        relabel_configs = [
          {
            source_labels = [ "__param_server" ];
            target_label = "instance";
          }
          {
            source_labels = [ "__param_server" ];
            target_label = "ups_server";
          }
          {
            source_labels = [ "__param_ups" ];
            target_label = "ups";
          }
        ];
      }
      {
        job_name = "nut-beast";
        metrics_path = "/ups_metrics";
        params = {
          # Use the stable LAN DNS hostname rather than .local/mDNS.
          server = [ (beastSpec.dnsName or beastSpec.name) ];
          ups = [ (hostInventory.toUpsName beastSpec.name) ];
        };
        static_configs = [
          {
            targets = [ "127.0.0.1:${toString nutExporterPort}" ];
          }
        ];
        relabel_configs = [
          {
            source_labels = [ "__param_server" ];
            target_label = "instance";
          }
          {
            source_labels = [ "__param_server" ];
            target_label = "ups_server";
          }
          {
            source_labels = [ "__param_ups" ];
            target_label = "ups";
          }
        ];
      }
      {
        job_name = "nut-frame";
        metrics_path = "/ups_metrics";
        params = {
          # Use the stable LAN DNS hostname rather than .local/mDNS.
          server = [ (frameSpec.dnsName or frameSpec.name) ];
          ups = [ (hostInventory.toUpsName frameSpec.name) ];
        };
        static_configs = [
          {
            targets = [ "127.0.0.1:${toString nutExporterPort}" ];
          }
        ];
        relabel_configs = [
          {
            source_labels = [ "__param_server" ];
            target_label = "instance";
          }
          {
            source_labels = [ "__param_server" ];
            target_label = "ups_server";
          }
          {
            source_labels = [ "__param_ups" ];
            target_label = "ups";
          }
        ];
      }
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
      {
        job_name = "smartctl";
        scheme = "https";
        tls_config = prometheusMtlsTlsConfig;
        static_configs = [
          {
            targets = [
              "${beastHostConfig.host.dnsName}:${toString beastPrometheusEndpoints.smartctl.port}"
            ];
            labels.instance = beastHostConfig.host.dnsName;
          }
        ];
      }
      {
        job_name = "jellyfin";
        scrape_interval = "5s";
        scheme = "https";
        tls_config = prometheusMtlsTlsConfig;
        static_configs = [
          {
            targets = [
              "${beastHostConfig.host.dnsName}:${toString beastPrometheusEndpoints.jellyfin.port}"
            ];
            labels.instance = beastHostConfig.host.dnsName;
          }
        ];
      }
      {
        job_name = "sabnzbd";
        scheme = "https";
        tls_config = prometheusMtlsTlsConfig;
        static_configs = [
          {
            targets = [
              "${sabnzbdHostConfig.host.dnsName}:${toString sabnzbdEndpoint.port}"
            ];
            labels.instance = sabnzbdHostConfig.host.dnsName;
          }
        ];
      }
      # TODO: Restore the beast IPMI scrape target when the local IPMI card is
      # back and the exporter is re-enabled on beast.
      {
        job_name = "vikunja";
        metrics_path = vikunjaEndpoint.path;
        scheme = "https";
        tls_config = prometheusMtlsTlsConfig;
        static_configs = [
          {
            targets = [ "${vikunjaHost}:${toString vikunjaEndpoint.port}" ];
            labels.instance = vikunjaHost;
          }
        ];
      }
    ];
  };

  # Blackbox exporter probes service endpoints to track reachability and latency.
  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = "127.0.0.1";
    configFile = (pkgs.formats.yaml { }).generate "blackbox.yml" {
      modules = blackboxModules;
    };
  };

  # Loki stores and indexes logs so Grafana can query them efficiently.
  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;
      server = {
        http_listen_address = "127.0.0.1";
        http_listen_port = lokiPort;
      };
      common = {
        path_prefix = "/var/lib/loki";
        replication_factor = 1;
        ring = {
          kvstore.store = "inmemory";
        };
      };
      schema_config = {
        configs = [
          {
            from = "2024-01-01";
            store = "tsdb";
            object_store = "filesystem";
            schema = "v13";
            index = {
              prefix = "index_";
              period = "24h";
            };
          }
        ];
      };
      storage_config = {
        filesystem.directory = "/var/lib/loki/chunks";
      };
      limits_config = {
        retention_period = lokiRetention;
      };
      compactor = {
        working_directory = "/var/lib/loki/retention";
        compaction_interval = "10m";
        retention_enabled = true;
        retention_delete_delay = "2h";
        retention_delete_worker_count = 50;
        delete_request_store = "filesystem";
      };
    };
  };

  host.observability.client = {
    nodeExporter = {
      listenAddress = "127.0.0.1";
      openFirewall = lib.mkForce false;
    };
  };
}
