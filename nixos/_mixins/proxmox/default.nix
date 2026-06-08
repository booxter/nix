{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.proxmox.apiCertificate;
  certInstallUnit = "proxmox-api-certificate.service";
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

  config = lib.mkMerge [
    {
      host.proxmox.apiCertificate.enable = lib.mkDefault (config.host.isProxmox && !config.host.isWork);
    }
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = config.services.proxmox-ve.enable;
          message = "host.proxmox.apiCertificate requires services.proxmox-ve.enable.";
        }
      ];

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
        requires = [
          "pve-cluster.service"
          "sops-install-secrets.service"
        ];
        after = [
          "pve-cluster.service"
          "sops-install-secrets.service"
        ];
        path = with pkgs; [
          coreutils
        ];
        script = ''
          set -euo pipefail
          install -D -o root -g root -m 0444 \
            ${config.sops.secrets.proxmoxApiServerCrt.path} \
            ${lib.escapeShellArg (toString cfg.certificatePath)}
          install -D -o root -g root -m 0400 \
            ${config.sops.secrets.proxmoxApiServerKey.path} \
            ${lib.escapeShellArg (toString cfg.keyPath)}
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
      };
    })
  ];
}
