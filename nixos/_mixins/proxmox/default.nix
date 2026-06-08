{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.proxmox.apiCertificate;
  exporterCfg = config.host.proxmox.prometheusExporter;
  certInstallUnit = "proxmox-api-certificate.service";
  internalPkiRootCaPath = import ../../../lib/home-internal-pki-root-ca.nix;
  pveExporterGroup = config.services.prometheus.exporters.pve.group;
  pveExporterUser = config.services.prometheus.exporters.pve.user;
  sopsInstallSecretsUnit = lib.optional config.sops.useSystemdActivation "sops-install-secrets.service";
in
{
  options.host.proxmox.apiCertificate = {
    enable = lib.mkEnableOption "internal PKI certificate installation for the Proxmox VE API";

    serverName = lib.mkOption {
      type = lib.types.str;
      default = config.host.dnsName;
      description = "Primary DNS name used for the Proxmox VE API certificate.";
    };

    serverAliases = lib.mkOption {
      type = with lib.types; listOf str;
      default = lib.unique [
        config.networking.hostName
        "${config.networking.hostName}.${hostInventory.site.lan.domain}"
        "${config.services.avahi.hostName}.local"
      ];
      description = "Additional DNS names included in the Proxmox VE API certificate.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8006;
      description = "Proxmox VE API HTTPS port.";
    };

    publicPort = lib.mkOption {
      type = lib.types.port;
      default = 443;
      description = "LAN-visible HTTPS port fronted by nginx for browser and blackbox access.";
    };

    secretPrefix = lib.mkOption {
      type = lib.types.str;
      default = "proxmox/api";
      description = "SOPS key prefix containing server_crt and server_key for pveproxy.";
    };

    certificatePath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/pve/local/pveproxy-ssl.pem";
      description = "Custom pveproxy certificate path.";
    };

    keyPath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/pve/local/pveproxy-ssl.key";
      description = "Custom pveproxy private key path.";
    };
  };

  options.host.proxmox.prometheusExporter = {
    enable = lib.mkEnableOption "per-node Proxmox VE Prometheus exporter";

    internalPort = lib.mkOption {
      type = lib.types.port;
      default = 19221;
      description = "Loopback-only prometheus-pve-exporter port.";
    };

    publicPort = lib.mkOption {
      type = lib.types.port;
      default = 9221;
      description = "LAN-visible mTLS port for Prometheus Proxmox VE scrapes.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to open the firewall for the mTLS exporter endpoint.";
    };

    apiUser = lib.mkOption {
      type = lib.types.str;
      default = "prometheus@pve";
      description = "Proxmox VE API user used by prometheus-pve-exporter.";
    };

    apiTokenName = lib.mkOption {
      type = lib.types.str;
      default = "metrics";
      description = "Proxmox VE API token name used by prometheus-pve-exporter.";
    };

    apiTokenValueSecret = lib.mkOption {
      type = lib.types.str;
      default = "proxmox/pve_exporter/token_value";
      description = "SOPS key containing the Proxmox VE API token value.";
    };

    verifySsl = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether prometheus-pve-exporter verifies the Proxmox VE API TLS certificate.";
    };
  };

  config = lib.mkMerge [
    {
      host.proxmox.apiCertificate.enable = lib.mkDefault (config.host.isProxmox && !config.host.isWork);
      host.proxmox.prometheusExporter.enable = lib.mkDefault (
        config.host.isProxmox && !config.host.isWork
      );
    }
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = config.services.proxmox-ve.enable;
          message = "host.proxmox.apiCertificate requires services.proxmox-ve.enable.";
        }
      ];

      # TODO: revisit whether direct LAN access to pveproxy's fixed 8006 port
      # is still needed after browser/API access has settled on nginx/443.
      host.internalHttps.services.proxmox = {
        enable = true;
        serverName = cfg.serverName;
        serverAliases = builtins.filter (alias: alias != cfg.serverName) cfg.serverAliases;
        localAliases = [ ];
        port = cfg.publicPort;
        secretPrefix = cfg.secretPrefix;
        upstream = "https://127.0.0.1:${toString cfg.port}";
        locationExtraConfig = ''
          proxy_ssl_name ${cfg.serverName};
          proxy_ssl_server_name on;
          proxy_ssl_trusted_certificate ${internalPkiRootCaPath};
          proxy_ssl_verify on;
        '';
      };

      sops.secrets.proxmoxApiServerCrt = {
        key = "${cfg.secretPrefix}/server_crt";
        mode = "0400";
        restartUnits = [
          certInstallUnit
          "pveproxy.service"
        ];
      };
      sops.secrets.proxmoxApiServerKey = {
        key = "${cfg.secretPrefix}/server_key";
        mode = "0400";
        restartUnits = [
          certInstallUnit
          "pveproxy.service"
        ];
      };

      systemd.services.proxmox-api-certificate = {
        description = "Install internal PKI certificate for Proxmox VE API";
        wantedBy = [ "multi-user.target" ];
        requiredBy = [ "pveproxy.service" ];
        before = [ "pveproxy.service" ];
        requires = [ "pve-cluster.service" ] ++ sopsInstallSecretsUnit;
        after = [ "pve-cluster.service" ] ++ sopsInstallSecretsUnit;
        path = with pkgs; [
          coreutils
        ];
        script = ''
          set -euo pipefail
          cert_path=${lib.escapeShellArg (toString cfg.certificatePath)}
          key_path=${lib.escapeShellArg (toString cfg.keyPath)}

          cleanup() {
            rm -f "$cert_path.tmp.$$" "$key_path.tmp.$$"
          }
          trap cleanup EXIT

          # /etc/pve is Proxmox pmxcfs, which rejects normal chmod/chown
          # operations. Copy files into it and let pmxcfs assign its own
          # root:www-data permissions.
          copy_pmxcfs() {
            src="$1"
            dst="$2"
            tmp="$dst.tmp.$$"
            cp "$src" "$tmp"
            mv -f "$tmp" "$dst"
          }

          copy_pmxcfs ${config.sops.secrets.proxmoxApiServerCrt.path} "$cert_path"
          copy_pmxcfs ${config.sops.secrets.proxmoxApiServerKey.path} "$key_path"
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
      };
    })
    (lib.mkIf exporterCfg.enable {
      assertions = [
        {
          assertion = config.services.proxmox-ve.enable;
          message = "host.proxmox.prometheusExporter requires services.proxmox-ve.enable.";
        }
      ];

      sops.secrets.proxmoxPveExporterTokenValue = {
        key = exporterCfg.apiTokenValueSecret;
        owner = pveExporterUser;
        group = pveExporterGroup;
        mode = "0400";
        restartUnits = [ "prometheus-pve-exporter.service" ];
      };

      sops.templates."pve-exporter.env" = {
        owner = pveExporterUser;
        group = pveExporterGroup;
        mode = "0400";
        content = ''
          PVE_USER=${exporterCfg.apiUser}
          PVE_TOKEN_NAME=${exporterCfg.apiTokenName}
          PVE_TOKEN_VALUE=${config.sops.placeholder.proxmoxPveExporterTokenValue}
          PVE_VERIFY_SSL=${lib.boolToString exporterCfg.verifySsl}
        '';
        restartUnits = [ "prometheus-pve-exporter.service" ];
      };

      services.prometheus.exporters.pve = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = exporterCfg.internalPort;
        environmentFile = config.sops.templates."pve-exporter.env".path;
      };

      systemd.services.prometheus-pve-exporter = {
        wants = [
          certInstallUnit
          "pveproxy.service"
        ]
        ++ sopsInstallSecretsUnit;
        after = [
          certInstallUnit
          "pveproxy.service"
        ]
        ++ sopsInstallSecretsUnit;
        environment.REQUESTS_CA_BUNDLE = toString internalPkiRootCaPath;
      };

      host.observability.client.prometheusMtlsEndpoints.pve = {
        enable = true;
        port = exporterCfg.publicPort;
        path = "/";
        upstream = "http://127.0.0.1:${toString exporterCfg.internalPort}";
        openFirewall = exporterCfg.openFirewall;
      };
    })
  ];
}
