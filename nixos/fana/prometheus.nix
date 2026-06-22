{
  config,
  lib,
  hostInventory,
  hostSpecName,
  outputs,
  pkgs,
  ...
}:
let
  internalPkiRootCaPath = import ../../lib/home-internal-pki-root-ca.nix;
  grafanaPort = 3000;
  prometheusPort = 9090;
  prometheusScrapeClient = config.host.observability.client.mtlsClients."prometheus-scrape-node";
  prometheusMtlsTlsConfig = {
    ca_file = toString internalPkiRootCaPath;
    cert_file = config.sops.secrets.prometheusScrapeNodeClientCrt.path;
    key_file = config.sops.secrets.prometheusScrapeNodeClientKey.path;
  };
  nodeScrapes = import ./scrapes/nodes.nix {
    inherit
      config
      hostInventory
      hostSpecName
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
      hostInventory
      outputs
      prometheusMtlsTlsConfig
      ;
  };
  serviceScrapes = import ./scrapes/services.nix {
    inherit
      hostInventory
      outputs
      prometheusMtlsTlsConfig
      ;
  };
  wireguardScrapes = import ./scrapes/wireguard.nix {
    inherit
      hostInventory
      lib
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
  prometheusRetention = "${toString retentionDays}d";
in
{
  assertions = nodeScrapes.assertions ++ blackboxScrapes.assertions;

  host.observability.client.mtlsClients."prometheus-scrape-node" = {
    enable = true;
    secretPrefix = "prometheus/scrape_node";
    commonName = "prometheus-node-scraper";
  };

  sops.secrets.prometheusScrapeNodeClientCrt = {
    key = "${prometheusScrapeClient.secretPrefix}/client_crt";
    owner = "prometheus";
    group = "prometheus";
    mode = "0400";
    restartUnits = [ "prometheus.service" ];
  };
  sops.secrets.prometheusScrapeNodeClientKey = {
    key = "${prometheusScrapeClient.secretPrefix}/client_key";
    owner = "prometheus";
    group = "prometheus";
    mode = "0400";
    restartUnits = [ "prometheus.service" ];
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
    ++ serviceScrapes.scrapeConfigs
    ++ wireguardScrapes.scrapeConfigs;
  };

  # Blackbox exporter probes service endpoints to track reachability and latency.
  services.prometheus.exporters.blackbox = blackboxScrapes.exporterConfig;
}
