{
  config,
  lib,
  facts,
  outputs,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.prometheus.server;
  internalPkiRootCaPath = config.host.internalPki.rootCaCertificate;
  prometheusPort = 9090;
  prometheusScrapeClient = config.host.internalPki.clients."prometheus-scrape-node";
  prometheusScrapeMaterialization = prometheusScrapeClient.materializations.default;
  blackboxScrapeMaterialization = prometheusScrapeClient.materializations.blackbox;
  prometheusMtlsTlsConfig = {
    ca_file = "${internalPkiRootCaPath}";
    cert_file = config.sops.secrets.${prometheusScrapeMaterialization.certificateSecretName}.path;
    key_file = config.sops.secrets.${prometheusScrapeMaterialization.keySecretName}.path;
  };
  blackboxHttpMtlsTlsConfig = {
    ca_file = "${internalPkiRootCaPath}";
    cert_file = config.sops.secrets.${blackboxScrapeMaterialization.certificateSecretName}.path;
    key_file = config.sops.secrets.${blackboxScrapeMaterialization.keySecretName}.path;
  };
  nodeScrapes = import ../../../fana/scrapes/nodes.nix {
    inherit
      config
      lib
      outputs
      prometheusMtlsTlsConfig
      ;
  };
  blackboxScrapes = import ../../../fana/scrapes/blackbox.nix {
    inherit
      config
      facts
      lib
      outputs
      blackboxHttpMtlsTlsConfig
      prometheusMtlsTlsConfig
      ;
  };
  proxmoxScrapes = import ../../../fana/scrapes/proxmox.nix {
    inherit
      config
      lib
      outputs
      prometheusMtlsTlsConfig
      ;
  };
  endpointScrapes = import ../../../fana/scrapes/endpoints.nix {
    inherit
      config
      lib
      outputs
      prometheusMtlsTlsConfig
      ;
  };
  wireguardScrapes = import ../../../fana/scrapes/wireguard.nix {
    inherit
      config
      lib
      outputs
      prometheusMtlsTlsConfig
      ;
  };
  nutScrapes = import ../../../fana/scrapes/nut.nix {
    inherit
      config
      lib
      outputs
      pkgs
      ;
  };
  prometheusRetention = "${toString cfg.retentionDays}d";
in
{
  options.host.observability.prometheus.server = {
    enable = lib.mkEnableOption "a Prometheus server";

    retentionDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 365;
      description = "Number of days to retain Prometheus metrics.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = nodeScrapes.assertions ++ endpointScrapes.assertions;

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
      ++ endpointScrapes.scrapeConfigs
      ++ wireguardScrapes.scrapeConfigs;
    };
  };
}
