{ config, lib, ... }:
let
  node = config.host.proxmox.node;
  enabled = node != null && config.host.observability.enable;
  internalPort = 19221;
  publicPort = 9221;
  token = config.host.proxmox.exporterToken;
  certInstallUnit = "proxmox-api-certificate.service";
  pkiRootCaPath = config.host.pki.authority.rootCaCertificate;
  pveExporterGroup = config.services.prometheus.exporters.pve.group;
  pveExporterUser = config.services.prometheus.exporters.pve.user;
  sopsInstallSecretsUnit = lib.optional config.sops.useSystemdActivation "sops-install-secrets.service";
in
{
  options.host.proxmox.exporterToken = lib.mkOption {
    type =
      with lib.types;
      nullOr (submodule {
        options = {
          apiUser = lib.mkOption { type = nonEmptyStr; };
          apiTokenName = lib.mkOption { type = nonEmptyStr; };
          apiTokenValueSecret = lib.mkOption { type = nonEmptyStr; };
        };
      });
    default =
      if enabled then
        {
          apiUser = "prometheus@pve";
          apiTokenName = "metrics";
          apiTokenValueSecret = "proxmox/pve_exporter/token_value";
        }
      else
        null;
    readOnly = true;
    internal = true;
    description = "Token provisioning record for the Proxmox Prometheus exporter.";
  };

  config = lib.mkIf enabled {
    host.web.services."proxmox-${config.networking.hostName}".metrics.default = {
      endpointName = "pve";
      discover = false;
      jobName = "pve";
      openFirewall = true;
      port = publicPort;
      path = "/";
      upstream = "http://127.0.0.1:${toString internalPort}";
    };

    host.observability.inventory.proxmox = {
      cluster = node.cluster;
      realm = config.host.realm;
      target = "${config.networking.hostName}:${toString config.host.observability.prometheusEndpoints.pve.port}";
      node = config.networking.hostName;
      pveTarget = node.apiServerName;
    };

    sops.secrets.proxmoxPveExporterTokenValue = {
      key = token.apiTokenValueSecret;
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
        PVE_USER=${token.apiUser}
        PVE_TOKEN_NAME=${token.apiTokenName}
        PVE_TOKEN_VALUE=${config.sops.placeholder.proxmoxPveExporterTokenValue}
        PVE_VERIFY_SSL=true
      '';
      restartUnits = [ "prometheus-pve-exporter.service" ];
    };

    services.prometheus.exporters.pve = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = internalPort;
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
  };
}
