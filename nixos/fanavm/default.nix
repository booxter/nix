{
  config,
  lib,
  hostInventory,
  outputs,
  pkgs,
  ...
}:
let
  internalPkiRootCaPath = import ../../lib/home-internal-pki-root-ca.nix;
  grafanaPort = 3000;
  prometheusPort = 9090;
  lokiPort = 3100;
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
  serviceScrapes = import ./scrapes/services.nix {
    inherit
      outputs
      prometheusMtlsTlsConfig
      ;
  };
  nutScrapes = import ./scrapes/nut.nix {
    inherit
      hostInventory
      lib
      pkgs
      ;
  };
  retentionDays = 365;
  retentionHours = retentionDays * 24;
  prometheusRetention = "${toString retentionDays}d";
  lokiRetention = "${toString retentionHours}h";
in
{
  imports = [
    ./grafana
    ./monitoring
  ];

  assertions = nodeScrapes.assertions ++ blackboxScrapes.assertions;

  sops = {
    defaultSopsFile = ../../secrets/prox-fanavm.yaml;
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
  host.internalHttps.services.loki = {
    enable = true;
    upstream = "http://127.0.0.1:${toString lokiPort}";
    mtls.enable = true;
    locationExtraConfig = ''
      client_max_body_size 0;
      proxy_request_buffering off;
    '';
  };

  systemd.services.prometheus = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };

  systemd.services.prometheus-nut-exporter = nutScrapes.exporterService;

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
    ++ nutScrapes.scrapeConfigs
    ++ blackboxScrapes.scrapeConfigs
    ++ serviceScrapes.scrapeConfigs;
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
