{ config, hostInventory, ... }:
let
  internalPkiRootCaPath = ../../common/_mixins/internal-pki/home-internal-pki-root-ca.crt;
  nodeExporterGroup = config.services.prometheus.exporters.node.group;
  nodeExporterUser = config.services.prometheus.exporters.node.user;
  vikunjaService = hostInventory.servicesById.vikunja;
  vikunjaPort = 3456;
  # Vikunja expects an IANA tz database name here, not a fixed abbreviation.
  vikunjaTimezone = "America/New_York";
in
{
  imports = [
    ./backup.nix
  ];

  sops.defaultSopsFile = ../../secrets/prox-orgvm.yaml;

  sops.secrets.vikunjaMailerPassword = {
    key = "vikunja/mailer/password";
    restartUnits = [ "vikunja.service" ];
  };
  sops.secrets.prometheusNodeExporterServerCrt = {
    key = "prometheus/node_exporter/server_crt";
    owner = nodeExporterUser;
    group = nodeExporterGroup;
    mode = "0400";
    restartUnits = [ "prometheus-node-exporter.service" ];
  };
  sops.secrets.prometheusNodeExporterServerKey = {
    key = "prometheus/node_exporter/server_key";
    owner = nodeExporterUser;
    group = nodeExporterGroup;
    mode = "0400";
    restartUnits = [ "prometheus-node-exporter.service" ];
  };

  sops.templates."vikunja-mailer.env" = {
    content = ''
      VIKUNJA_MAILER_PASSWORD=${config.sops.placeholder.vikunjaMailerPassword}
    '';
    restartUnits = [ "vikunja.service" ];
  };
  sops.templates."node-exporter-web-config.yaml" = {
    owner = nodeExporterUser;
    group = nodeExporterGroup;
    mode = "0400";
    content = ''
      tls_server_config:
        cert_file: ${config.sops.secrets.prometheusNodeExporterServerCrt.path}
        key_file: ${config.sops.secrets.prometheusNodeExporterServerKey.path}
        client_auth_type: RequireAndVerifyClientCert
        client_ca_file: ${internalPkiRootCaPath}
    '';
    restartUnits = [ "prometheus-node-exporter.service" ];
  };

  services.vikunja = {
    enable = true;
    environmentFiles = [ config.sops.templates."vikunja-mailer.env".path ];
    frontendScheme = "https";
    frontendHostname = vikunjaService.publicHost;
    port = vikunjaPort;
    settings = {
      defaultsettings = {
        timezone = vikunjaTimezone;
        week_start = 1;
      };
      metrics.enabled = true;
      mailer = {
        enabled = true;
        host = "smtp.gmail.com";
        port = 587;
        username = "ihar.hrachyshka@gmail.com";
        fromemail = "ihar.hrachyshka@gmail.com";
      };
      service = {
        timezone = vikunjaTimezone;
        enableregistration = false;
      };
    };
  };
  services.prometheus.exporters.node.extraFlags = [
    "--web.config.file=${config.sops.templates."node-exporter-web-config.yaml".path}"
  ];

  systemd.services.prometheus-node-exporter = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };

  networking.firewall.allowedTCPPorts = [ vikunjaPort ];
}
