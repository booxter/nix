{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  arrServices = import ../../lib/arr-services.nix {
    grafanaProbeUrl = "http://127.0.0.1:${toString grafanaPort}/";
    srvarrProbeHost = outputs.nixosConfigurations.prox-srvarrvm.config.host.dnsName;
    srvarrPorts = {
      audiobookshelf = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.audiobookshelf.port;
      bazarr = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.bazarr.port;
      lidarr = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.lidarr.port;
      prowlarr = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.prowlarr.port;
      radarr = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.radarr.port;
      readarr = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.readarr.port;
      readarrAudio = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.readarr-audiobook.port;
      sabnzbd = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.sabnzbd.guiPort;
      sonarr = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.sonarr.port;
      transmission = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.transmission.uiPort;
    };
  };
  dnsProbeTargets = [
    {
      resolver = "pi5";
      resolver_title = "pi5 dnsmasq";
      target = "192.168.1.1:53";
    }
    {
      resolver = "upstream";
      resolver_title = "upstream 192.168.0.1";
      target = "192.168.0.1:53";
    }
    {
      resolver = "google";
      resolver_title = "Google 8.8.8.8";
      target = "8.8.8.8:53";
    }
  ];
  grafanaPort = 3000;
  prometheusPort = 9090;
  lokiPort = 3100;
  smartctlExporterPort = 9633;
  retentionDays = 14;
  retentionHours = retentionDays * 24;
  prometheusRetention = "${toString retentionDays}d";
  lokiRetention = "${toString retentionHours}h";
  remoteNixosNodeTargetConfigs =
    map
      (name: {
        labels = {
          host_network_charts = lib.boolToString (!outputs.nixosConfigurations.${name}.config.host.isProxmox);
          host_network_source =
            if outputs.nixosConfigurations.${name}.config.host.isProxmox then "classified" else "node";
        };
        targets = [ "${outputs.nixosConfigurations.${name}.config.host.dnsName}:9100" ];
      })
      (
        builtins.filter (
          name:
          !(lib.hasPrefix "local-" name)
          && name != "prox-fanavm"
          && !(outputs.nixosConfigurations.${name}.config.host.isWork or false)
        ) (builtins.attrNames outputs.nixosConfigurations)
      );
  remoteDarwinNodeTargetConfigs =
    map
      (name: {
        labels = {
          host_network_charts = "true";
          host_network_source = "node";
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
            type = "prometheus";
            access = "proxy";
            url = "http://127.0.0.1:${toString prometheusPort}";
            isDefault = true;
            editable = false;
          }
          {
            name = "Loki";
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
              instance = "${config.host.dnsName}:${toString config.services.prometheus.exporters.node.port}";
            };
          }
        ]
        ++ remoteNodeTargetConfigs;
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
        }) arrServices;
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
    ];
  };

  # Blackbox exporter probes service endpoints to track reachability and latency.
  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = "127.0.0.1";
    configFile = (pkgs.formats.yaml { }).generate "blackbox.yml" {
      modules.dns_udp = {
        dns = {
          preferred_ip_protocol = "ip4";
          query_name = "example.com";
          query_type = "A";
          transport_protocol = "udp";
          valid_rcodes = [ "NOERROR" ];
        };
        prober = "dns";
        timeout = "5s";
      };
      modules.http_service = {
        http = {
          follow_redirects = true;
          preferred_ip_protocol = "ip4";
        };
        prober = "http";
        timeout = "5s";
      };
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
