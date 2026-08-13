{ config, lib, ... }:
let
  cfg = config.host.proxmox.prometheusExporter;
  certInstallUnit = "proxmox-api-certificate.service";
  pkiRootCaPath = config.host.pki.rootCaCertificate;
  pveExporterGroup = config.services.prometheus.exporters.pve.group;
  pveExporterUser = config.services.prometheus.exporters.pve.user;
  sopsInstallSecretsUnit = lib.optional config.sops.useSystemdActivation "sops-install-secrets.service";
in
{
  config = lib.mkMerge [
    {
      host.proxmox.prometheusExporter.enable = lib.mkDefault (
        config.host.proxmox.node.enable && config.host.observability.enable
      );
    }
    (lib.mkIf cfg.enable {
      sops.secrets.proxmoxPveExporterTokenValue = {
        key = cfg.apiTokenValueSecret;
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
          PVE_USER=${cfg.apiUser}
          PVE_TOKEN_NAME=${cfg.apiTokenName}
          PVE_TOKEN_VALUE=${config.sops.placeholder.proxmoxPveExporterTokenValue}
          PVE_VERIFY_SSL=${lib.boolToString cfg.verifySsl}
        '';
        restartUnits = [ "prometheus-pve-exporter.service" ];
      };

      services.prometheus.exporters.pve = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = cfg.internalPort;
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
        environment.REQUESTS_CA_BUNDLE = "${pkiRootCaPath}";
      };
    })
  ];
}
