{
  config,
  lib,
  outputs,
  ...
}:
let
  grafanaPort = 3000;
  prometheusPort = 9090;
  lokiPort = 3100;
  retentionDays = 14;
  retentionHours = retentionDays * 24;
  prometheusRetention = "${toString retentionDays}d";
  lokiRetention = "${toString retentionHours}h";
  remoteNodeTargets = map (name: "${name}:9100") (
    builtins.filter (
      name:
      !(lib.hasPrefix "local-" name)
      && name != "prox-fanavm"
      && !(outputs.nixosConfigurations.${name}.config.host.isWork or false)
    ) (builtins.attrNames outputs.nixosConfigurations)
  );
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
            ]
            ++ remoteNodeTargets;
          }
        ];
      }
    ];
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
