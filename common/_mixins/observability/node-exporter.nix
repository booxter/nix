{
  config,
  lib,
  pkgs,
  ...
}:
let
  observabilityCfg = config.host.observability;
  cfg = observabilityCfg.nodeExporter;
  secretPrefix = "prometheus/node_exporter";
  certificateSecret = config.sops.secrets.prometheusNodeExporterServerCrt;
  keySecret = config.sops.secrets.prometheusNodeExporterServerKey;
  webConfig = (pkgs.formats.yaml { }).generate "node-exporter-web-config.yaml" {
    tls_server_config = {
      cert_file = certificateSecret.path;
      key_file = keySecret.path;
      client_auth_type = "RequireAndVerifyClientCert";
      client_ca_file = config.host.pki.authority.rootCaCertificate;
    };
  };
in
{
  options.host.observability.nodeExporter = {
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Address for the Prometheus node exporter to bind.";
    };

    serviceUser = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      description = "Platform service account that runs the Prometheus node exporter.";
    };

    serviceGroup = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      description = "Platform service group that runs the Prometheus node exporter.";
    };

    textfile.directories = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      internal = true;
      description = "Directories containing metrics for the node exporter textfile collector.";
    };

    mtls.enable = lib.mkEnableOption "mTLS protection for the Prometheus node exporter";
  };

  config = lib.mkIf (observabilityCfg.enable && cfg.mtls.enable) {
    host.pki.certificates."observability_endpoint_server/node_exporter" = {
      category = "observability_endpoint_server";
      name = "node_exporter";
      commonName = "prometheus-node_exporter.${config.networking.hostName}";
      sans = config.host.network.certificateDnsNames;
      port = config.services.prometheus.exporters.node.port;
      inherit secretPrefix;
    };

    sops.secrets = {
      prometheusNodeExporterServerCrt = {
        key = "${secretPrefix}/server_crt_unencrypted";
        owner = cfg.serviceUser;
        group = cfg.serviceGroup;
        mode = "0400";
      };

      prometheusNodeExporterServerKey = {
        key = "${secretPrefix}/server_key";
        owner = cfg.serviceUser;
        group = cfg.serviceGroup;
        mode = "0400";
      };
    };

    services.prometheus.exporters.node.extraFlags = [
      "--web.config.file=${webConfig}"
    ];
  };
}
