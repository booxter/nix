{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.prometheus.server;
  alertmanagerCfg = config.host.observability.alertmanager;
  pkiRootCaPath = config.host.pki.authority.rootCaCertificate;
  prometheusScrapeClient = config.host.pki.clients."prometheus-scrape-node";
  prometheusScrapeMaterialization = prometheusScrapeClient.materializations.default;
  blackboxScrapeMaterialization = prometheusScrapeClient.materializations.blackbox;
  prometheusMtlsTlsConfig = {
    ca_file = "${pkiRootCaPath}";
    cert_file = prometheusScrapeMaterialization.certificatePath;
    key_file = prometheusScrapeMaterialization.keyPath;
  };
  blackboxHttpMtlsTlsConfig = {
    ca_file = "${pkiRootCaPath}";
    cert_file = blackboxScrapeMaterialization.certificatePath;
    key_file = blackboxScrapeMaterialization.keyPath;
  };
  localHost = config.networking.hostName;
  nixosConfigurations = outputs.nixosConfigurations // {
    ${localHost} = { inherit config; };
  };
  observabilityInventory = {
    nixos = lib.mapAttrs (
      _: configuration: configuration.config.host.observability.inventory
    ) nixosConfigurations;
    all = lib.mapAttrs (_: configuration: configuration.config.host.observability.inventory) (
      nixosConfigurations // outputs.darwinConfigurations
    );
  };
  nodeScrapes = import ./scrapes/nodes.nix {
    inherit
      config
      lib
      observabilityInventory
      prometheusMtlsTlsConfig
      ;
  };
  blackboxScrapes = import ./scrapes/blackbox {
    inherit
      config
      lib
      observabilityInventory
      outputs
      blackboxHttpMtlsTlsConfig
      prometheusMtlsTlsConfig
      ;
  };
  proxmoxScrapes = import ./scrapes/proxmox.nix {
    inherit
      lib
      observabilityInventory
      prometheusMtlsTlsConfig
      ;
  };
  endpointScrapes = import ./scrapes/endpoints.nix {
    inherit
      lib
      observabilityInventory
      prometheusMtlsTlsConfig
      ;
  };
  nutScrapes = import ./scrapes/nut.nix {
    inherit
      config
      lib
      outputs
      pkgs
      ;
  };
  monitoringPackage = pkgs.callPackage ../policy/package.nix {
    capacityAlertPolicy = {
      cpu = {
        warningPercent = 80;
        criticalPercent = 90;
      };
      memory = {
        warningPercent = 80;
        criticalPercent = 90;
      };
    };
  };
in
{
  options.host.observability.prometheus.server = {
    enable = lib.mkEnableOption "a Prometheus server";

    port = lib.mkOption {
      type = lib.types.port;
      default = 9090;
      readOnly = true;
      internal = true;
      description = "Loopback Prometheus HTTP port.";
    };

  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.length config.services.prometheus.alertmanagers == 1;
        message = "Prometheus expects a single local Alertmanager target.";
      }
    ]
    ++ blackboxScrapes.assertions
    ++ nodeScrapes.assertions
    ++ endpointScrapes.assertions;

    host.observability.blackbox = {
      enable = true;
      modules = blackboxScrapes.modules;
      port = 9115;
    };

    host.pki.clients."prometheus-scrape-node" = {
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
      port = cfg.port;
      retentionTime = "365d";
      alertmanagers = lib.optional alertmanagerCfg.enable {
        static_configs = [
          {
            targets = [ "127.0.0.1:${toString alertmanagerCfg.port}" ];
          }
        ];
      };
      ruleFiles = monitoringPackage.prometheusRuleFiles;
      scrapeConfigs = [
        {
          job_name = "alertmanager";
          static_configs = [
            {
              targets = [ "127.0.0.1:${toString alertmanagerCfg.port}" ];
              labels.instance = config.networking.hostName;
            }
          ];
        }
      ]
      ++ lib.optional config.host.observability.grafana.enable {
        job_name = "grafana";
        static_configs = [
          {
            targets = [
              "127.0.0.1:${toString config.services.grafana.settings.server.http_port}"
            ];
            labels.instance = config.networking.hostName;
          }
        ];
      }
      ++ [
        {
          job_name = "prometheus";
          static_configs = [
            {
              targets = [ "127.0.0.1:${toString cfg.port}" ];
            }
          ];
        }
      ]
      ++ nodeScrapes.scrapeConfigs
      ++ proxmoxScrapes.scrapeConfigs
      ++ nutScrapes.scrapeConfigs
      ++ blackboxScrapes.scrapeConfigs
      ++ endpointScrapes.scrapeConfigs;
    };
  };
}
