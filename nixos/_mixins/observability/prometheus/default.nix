{
  config,
  lib,
  hostInventory,
  outputs,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.prometheus;
  hostname = config.networking.hostName;
  prometheusService = hostInventory.servicesById.prometheus;
  internalPkiRootCaPath = config.host.internalPki.rootCaCertificate;
  grafanaPort = config.host.observability.grafana.port;
  prometheusPort = cfg.port;
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
      config
      hostInventory
      lib
      outputs
      prometheusMtlsTlsConfig
      ;
  };
  endpointScrapes = import ./scrapes/endpoints.nix {
    inherit
      hostInventory
      lib
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
      config
      hostInventory
      lib
      pkgs
      ;
  };
  monitoringPackage = pkgs.callPackage ./monitoring/package.nix { };
  retentionDays = cfg.retentionDays;
  prometheusRetention = "${toString retentionDays}d";
in
{
  options.host.observability.prometheus = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = hostInventory.serviceRunsOn hostname prometheusService;
      readOnly = true;
      internal = true;
      description = "Whether inventory assigns the Prometheus service to this host.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9090;
      description = "Loopback port on which Prometheus listens.";
    };

    retentionDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 365;
      description = "Number of days for which Prometheus retains metrics.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      assertions =
        nodeScrapes.assertions
        ++ blackboxScrapes.assertions
        ++ proxmoxScrapes.assertions
        ++ endpointScrapes.assertions;

      host.observability.nodeExporter = {
        listenAddress = "127.0.0.1";
        mtls.enable = false;
        openFirewall = lib.mkForce false;
      };

      host.observability.blackbox = {
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
        ruleFiles = monitoringPackage.prometheusRuleFiles;
        scrapeConfigs = [
          {
            job_name = "prometheus";
            static_configs = [
              {
                targets = [ "127.0.0.1:${toString prometheusPort}" ];
                labels.instance = hostname;
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
    })
  ];
}
