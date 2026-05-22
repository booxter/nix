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
  lan = hostInventory.site.lan;
  pi5Spec = hostInventory.nixosHostSpecsByName.pi5;
  prx1Spec = hostInventory.nixosHostSpecsByName."prx1-lab";
  serviceCatalog = import ../../lib/services.nix {
    inherit hostInventory;
    grafanaProbeUrl = "http://127.0.0.1:${toString grafanaPort}/";
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
  };
  dnsProbeTargets = [
    {
      resolver = "pi5";
      resolver_title = "pi5 dnsmasq";
      target = "${lan.gateway.address}:53";
    }
    {
      resolver = "upstream";
      resolver_title = "upstream ${lan.upstreamGateway}";
      target = "${lan.upstreamGateway}:53";
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
      probe = "upstream";
      probe_title = "Upstream ${lan.upstreamGateway}";
      target = lan.upstreamGateway;
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
  jellyfinExporterPort = 9594;
  sabnzbdExporterPort =
    outputs.nixosConfigurations.prox-srvarrvm.config.services.prometheus.exporters.sabnzbd.port;
  nutExporterPort = 9199;
  smartctlExporterPort = 9633;
  vikunjaHost = outputs.nixosConfigurations.prox-orgvm.config.host.dnsName;
  vikunjaPort = outputs.nixosConfigurations.prox-orgvm.config.services.vikunja.port;
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
  remoteNixosNodeTargetConfigs =
    map
      (name: {
        labels = {
          host_network_charts = lib.boolToString (!outputs.nixosConfigurations.${name}.config.host.isProxmox);
          host_network_source =
            if outputs.nixosConfigurations.${name}.config.host.isProxmox then "classified" else "node";
          host_class = hostClassForName name;
          host_virtual = lib.boolToString (isVirtualNodeName name);
          instance = outputs.nixosConfigurations.${name}.config.host.dnsName;
        };
        targets = [ "${outputs.nixosConfigurations.${name}.config.host.dnsName}:9100" ];
      })
      (
        builtins.filter (
          name:
          !(lib.hasPrefix "local-" name)
          && name != "prox-fanavm"
          && name != "prox-deskvm"
          && !(outputs.nixosConfigurations.${name}.config.host.isWork or false)
        ) (builtins.attrNames outputs.nixosConfigurations)
      );
  remoteDarwinNodeTargetConfigs =
    map
      (name: {
        labels = {
          host_network_charts = "true";
          host_network_source = "node";
          host_class = "hardware";
          host_virtual = "false";
          instance = outputs.darwinConfigurations.${name}.config.host.dnsName;
        };
        targets = [ "${outputs.darwinConfigurations.${name}.config.host.dnsName}:9100" ];
      })
      (
        builtins.filter (
          name:
          (outputs.darwinConfigurations.${name}.config.host.observability.client.enable or false)
          && !(outputs.darwinConfigurations.${name}.config.host.isWork or false)
        ) (builtins.attrNames outputs.darwinConfigurations)
      );
  remoteNodeTargetConfigs = remoteNixosNodeTargetConfigs ++ remoteDarwinNodeTargetConfigs;
  mkBlackboxProbeSourceForConfig = hostConfig: {
    exporter = "${hostConfig.host.dnsName}:${toString hostConfig.services.prometheus.exporters.blackbox.port}";
    source = hostConfig.services.avahi.hostName;
  };
  remoteBlackboxProbeSourceConfigs =
    map (name: mkBlackboxProbeSourceForConfig outputs.nixosConfigurations.${name}.config)
      (
        builtins.filter (
          name:
          !(lib.hasPrefix "local-" name)
          && name != "prox-fanavm"
          && outputs.nixosConfigurations.${name}.config.host.observability.client.blackbox.enable
        ) (builtins.attrNames outputs.nixosConfigurations)
      );
  blackboxProbeSourceConfigs = [
    {
      exporter = "127.0.0.1:${toString config.services.prometheus.exporters.blackbox.port}";
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
      action = "labeldrop";
      regex = "prober_address";
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
    restartUnits = [ "grafana.service" ];
  };
  sops.secrets.grafanaAlertingTelegramChatId = {
    key = "grafana/alerting/telegram/chat_id";
    owner = "grafana";
    group = "grafana";
    mode = "0400";
    restartUnits = [ "grafana.service" ];
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
        http_addr = "0.0.0.0";
        http_port = grafanaPort;
        domain = "${config.services.avahi.hostName}.local";
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
        groups = [
          {
            orgId = 1;
            name = "dns-health";
            folder = "Fana";
            interval = "30s";
            rules = [
              (mkGrafanaPromRule {
                uid = "dns_probe_down";
                title = "DNS Resolver Probe Down";
                expr = "probe_success{job=\"blackbox-dns\"}";
                comparator = "lt";
                threshold = 1;
                forDuration = "2m";
                annotations = {
                  summary = "DNS probe down: {{ $labels.resolver_title }}";
                  description = "Resolver {{ $labels.resolver_title }} is failing blackbox DNS probes from fana.";
                };
                labels = {
                  severity = "critical";
                  category = "dns";
                };
              })
              (mkGrafanaPromRule {
                uid = "dns_upstream_failures";
                title = "DNS Upstream Failures";
                expr = "sum by (instance) (rate(dnsmasq_servers_queries_failed{job=\"dnsmasq\"}[5m]))";
                comparator = "gt";
                threshold = 0;
                forDuration = "10m";
                annotations = {
                  summary = "DNS upstream failures on {{ $labels.instance }}";
                  description = "dnsmasq on {{ $labels.instance }} has been seeing upstream query failures for 10 minutes.";
                };
                labels = {
                  severity = "warning";
                  category = "dns";
                };
              })
            ];
          }
          {
            orgId = 1;
            name = "thermal-health";
            folder = "Fana";
            interval = "30s";
            rules = [
              (mkGrafanaPromRule {
                uid = "thermal_cpu_hot";
                title = "CPU Temperature High";
                expr = "max by(instance) ((node_thermal_zone_temp{job=\"node\",host_class=\"hardware\",type=~\"cpu-thermal|x86_pkg_temp\"} or node_hwmon_temp_celsius{job=\"node\",host_class=\"hardware\",chip=~\"platform_coretemp_0|pci0000:00_0000:00:18_3\",sensor=\"temp1\"}) or host_observability_darwin_temperature_group_max_celsius{job=\"node\",host_class=\"hardware\",group=\"cpu\"})";
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
                expr = "max by(instance) (node_hwmon_temp_celsius{job=\"node\",host_class=\"hardware\",chip=~\"nvme_.*\",sensor=\"temp1\"} or host_observability_hba_temperature_celsius{job=\"node\",host_class=\"hardware\",sensor=\"roc\"} or host_observability_darwin_temperature_group_max_celsius{job=\"node\",host_class=\"hardware\",group=\"storage\"})";
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
                expr = "host_observability_hba_collect_success{job=\"node\",host_class=\"hardware\"}";
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
                expr = "host_observability_darwin_ismc_collect_success{job=\"node\",host_class=\"hardware\"}";
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
        ];
      };
    };
  };

  systemd.services.grafana = {
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
        ]
        ++ remoteNodeTargetConfigs;
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
        static_configs = mkBlackboxStaticConfigs blackboxProbeSourceConfigs wanIcmpProbeTargets;
        relabel_configs = blackboxProbeRelabelConfigs;
      }
      {
        job_name = "blackbox-tcp";
        metrics_path = "/probe";
        params.module = [ "tcp_connect_ipv4" ];
        scrape_interval = "5s";
        static_configs = mkBlackboxStaticConfigs blackboxProbeSourceConfigs wanTcpProbeTargets;
        relabel_configs = blackboxProbeRelabelConfigs;
      }
      {
        job_name = "dnsmasq";
        static_configs = [
          {
            targets = [
              "${outputs.nixosConfigurations.pi5.config.host.dnsName}:${toString outputs.nixosConfigurations.pi5.config.services.prometheus.exporters.dnsmasq.port}"
            ];
          }
        ];
      }
      {
        job_name = "smartctl";
        static_configs = [
          {
            targets = [
              "${outputs.nixosConfigurations.beast.config.host.dnsName}:${toString smartctlExporterPort}"
            ];
            labels.instance = outputs.nixosConfigurations.beast.config.host.dnsName;
          }
        ];
      }
      {
        job_name = "jellyfin";
        scrape_interval = "5s";
        static_configs = [
          {
            targets = [
              "${outputs.nixosConfigurations.beast.config.host.dnsName}:${toString jellyfinExporterPort}"
            ];
            labels.instance = outputs.nixosConfigurations.beast.config.host.dnsName;
          }
        ];
      }
      {
        job_name = "sabnzbd";
        static_configs = [
          {
            targets = [
              "${outputs.nixosConfigurations.prox-srvarrvm.config.host.dnsName}:${toString sabnzbdExporterPort}"
            ];
            labels.instance = outputs.nixosConfigurations.prox-srvarrvm.config.host.dnsName;
          }
        ];
      }
      # TODO: Restore the beast IPMI scrape target when the local IPMI card is
      # back and the exporter is re-enabled on beast.
      {
        job_name = "vikunja";
        metrics_path = "/api/v1/metrics";
        static_configs = [
          {
            targets = [ "${vikunjaHost}:${toString vikunjaPort}" ];
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
        http_listen_address = "0.0.0.0";
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
    lokiWriteUrl = "http://127.0.0.1:${toString lokiPort}/loki/api/v1/push";
    nodeExporter = {
      listenAddress = "127.0.0.1";
      openFirewall = lib.mkForce false;
    };
  };

  networking.firewall.allowedTCPPorts = [
    grafanaPort
    lokiPort
  ];
}
