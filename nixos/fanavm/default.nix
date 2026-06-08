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
  internalPkiRootCaPath = import ../../lib/home-internal-pki-root-ca.nix;
  lan = hostInventory.site.lan;
  prx1Spec = hostInventory.nixosHostSpecsByName."prx1-lab";
  srvarrHostConfig = outputs.nixosConfigurations.prox-srvarrvm.config;
  alertmanagerPort = 9093;
  grafanaPort = 3000;
  prometheusPort = 9090;
  lokiPort = 3100;
  nutExporterPort = 9199;
  beastHostConfig = outputs.nixosConfigurations.beast.config;
  beastPrometheusEndpoints = beastHostConfig.host.observability.client.prometheusMtlsEndpoints;
  lolekEndpoint = beastPrometheusEndpoints.lolek;
  sabnzbdHostConfig = srvarrHostConfig;
  sabnzbdEndpoint = sabnzbdHostConfig.host.observability.client.prometheusMtlsEndpoints.sabnzbd;
  prometheusMtlsTlsConfig = {
    ca_file = toString internalPkiRootCaPath;
    cert_file = config.sops.secrets.prometheusScrapeNodeClientCrt.path;
    key_file = config.sops.secrets.prometheusScrapeNodeClientKey.path;
  };
  nodeScrapes = import ./scrapes/nodes.nix {
    inherit
      config
      lib
      outputs
      prometheusMtlsTlsConfig
      ;
  };
  blackboxScrapes = import ./scrapes/blackbox.nix {
    inherit
      config
      grafanaPort
      hostInventory
      lib
      outputs
      pkgs
      prometheusMtlsTlsConfig
      ;
  };
  proxmoxScrapes = import ./scrapes/proxmox.nix {
    inherit
      lib
      outputs
      prometheusMtlsTlsConfig
      ;
  };
  vikunjaHostConfig = outputs.nixosConfigurations.prox-orgvm.config;
  vikunjaHost = vikunjaHostConfig.host.dnsName;
  vikunjaEndpoint = vikunjaHostConfig.host.observability.client.prometheusMtlsEndpoints.vikunja;
  retentionDays = 365;
  retentionHours = retentionDays * 24;
  prometheusRetention = "${toString retentionDays}d";
  lokiRetention = "${toString retentionHours}h";
  grafanaAlertmanagerUid = "P3A7B7B4C0D9E6F1";
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

  assertions = nodeScrapes.assertions ++ blackboxScrapes.assertions;

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
    restartUnits = [ "alertmanager.service" ];
  };
  sops.secrets.grafanaAlertingTelegramChatId = {
    key = "grafana/alerting/telegram/chat_id";
    owner = "grafana";
    group = "grafana";
    mode = "0400";
    restartUnits = [ "alertmanager.service" ];
  };
  sops.templates."alertmanager.env" = {
    mode = "0400";
    content = ''
      TELEGRAM_CHAT_ID=${config.sops.placeholder.grafanaAlertingTelegramChatId}
    '';
    restartUnits = [ "alertmanager.service" ];
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
            jsonData = {
              manageAlerts = true;
              alertmanagerUid = grafanaAlertmanagerUid;
            };
            editable = false;
          }
          {
            name = "Alertmanager";
            uid = grafanaAlertmanagerUid;
            type = "alertmanager";
            access = "proxy";
            url = "http://127.0.0.1:${toString alertmanagerPort}";
            jsonData = {
              implementation = "prometheus";
              handleGrafanaManagedAlerts = false;
            };
            editable = false;
          }
          {
            name = "Loki";
            uid = grafanaLokiUid;
            type = "loki";
            access = "proxy";
            url = "http://127.0.0.1:${toString lokiPort}";
            jsonData = {
              manageAlerts = false;
            };
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
          {
            orgId = 1;
            uid = "ups_exporter_down";
          }
          {
            orgId = 1;
            uid = "ups_on_battery";
          }
          {
            orgId = 1;
            uid = "ups_low_battery";
          }
          {
            orgId = 1;
            uid = "internal_pki_cert_missing";
          }
          {
            orgId = 1;
            uid = "internal_pki_cert_expiry_warning";
          }
          {
            orgId = 1;
            uid = "internal_pki_cert_expiry_critical";
          }
          {
            orgId = 1;
            uid = "public_tls_cert_expiry_warning";
          }
          {
            orgId = 1;
            uid = "public_tls_cert_expiry_critical";
          }
          {
            orgId = 1;
            uid = "pki_rotation_controller_failed";
          }
          {
            orgId = 1;
            uid = "pki_rotation_controller_stale";
          }
          {
            orgId = 1;
            uid = "thermal_cpu_hot";
          }
          {
            orgId = 1;
            uid = "thermal_storage_hot";
          }
          {
            orgId = 1;
            uid = "thermal_hba_export_failed";
          }
          {
            orgId = 1;
            uid = "thermal_hdd_hot";
          }
          {
            orgId = 1;
            uid = "darwin_ismc_export_failed";
          }
        ];
        groups = [
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
    ]
    ++ nodeScrapes.scrapeConfigs
    ++ proxmoxScrapes.scrapeConfigs
    ++ [
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
    ]
    ++ blackboxScrapes.scrapeConfigs
    ++ [
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
        job_name = "lolek";
        metrics_path = lolekEndpoint.path;
        scheme = "https";
        tls_config = prometheusMtlsTlsConfig;
        static_configs = [
          {
            targets = [
              "${beastHostConfig.host.dnsName}:${toString lolekEndpoint.port}"
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
  services.prometheus.exporters.blackbox = blackboxScrapes.exporterConfig;

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
