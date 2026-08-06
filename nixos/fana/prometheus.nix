{
  config,
  lib,
  hostInventory,
  outputs,
  pkgs,
  ...
}:
let
  internalPkiRootCaPath = config.host.internalPki.rootCaCertificate;
  grafanaPort = 3000;
  prometheusPort = 9090;
  prometheusScrapeClient = config.host.internalPki.clients."prometheus-scrape-node";
  prometheusScrapeMaterialization = prometheusScrapeClient.materializations.default;
  blackboxScrapeMaterialization = prometheusScrapeClient.materializations.blackbox;
  prometheusMtlsTlsConfig = {
    ca_file = toString internalPkiRootCaPath;
    cert_file = config.sops.secrets.${prometheusScrapeMaterialization.certificateSecretName}.path;
    key_file = config.sops.secrets.${prometheusScrapeMaterialization.keySecretName}.path;
  };
  blackboxHttpMtlsTlsConfig = {
    ca_file = toString internalPkiRootCaPath;
    cert_file = config.sops.secrets.${blackboxScrapeMaterialization.certificateSecretName}.path;
    key_file = config.sops.secrets.${blackboxScrapeMaterialization.keySecretName}.path;
  };
  nodeScrapes = import ./scrapes/nodes.nix {
    inherit
      config
      hostInventory
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
      blackboxHttpMtlsTlsConfig
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
  unpollerScrapes = import ./scrapes/unpoller.nix { };
  retentionDays = 365;
  prometheusRetention = "${toString retentionDays}d";
in
{
  assertions = nodeScrapes.assertions;

  host.observability.blackbox = {
    enable = true;
    modules = blackboxScrapes.modules;
    port = 9115;
  };

  host.internalPki.clients."prometheus-scrape-node" = {
    enable = true;
    category = "observability";
    secretPrefix = "prometheus/scrape_node";
    commonName = "prometheus-node-scraper";
    materializations = {
      default = {
        owner = "prometheus";
        group = "prometheus";
        restartUnits = [ "prometheus.service" ];
      };
      blackbox = lib.mkIf blackboxScrapes.usesHttpMtls {
        owner = "blackbox-exporter";
        group = "blackbox-exporter";
        restartUnits = [ "prometheus-blackbox-exporter.service" ];
      };
    };
  };

  users.groups.blackbox-exporter = lib.mkIf blackboxScrapes.usesHttpMtls { };
  users.users.blackbox-exporter = lib.mkIf blackboxScrapes.usesHttpMtls {
    description = "Prometheus blackbox exporter service user";
    isSystemUser = true;
    group = "blackbox-exporter";
  };

  systemd.services.prometheus = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };
  systemd.services.prometheus-blackbox-exporter = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
    serviceConfig = lib.mkIf blackboxScrapes.usesHttpMtls {
      DynamicUser = false;
    };
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
    ++ unpollerScrapes.scrapeConfigs
    ++ wireguardScrapes.scrapeConfigs;
  };
}
