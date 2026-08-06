{
  config,
  lib,
  pkgs,
  ...
}:
let
  clientCfg = config.host.observability.client;
  cfg = clientCfg.nodeExporter;
  certificateSecret = config.sops.secrets.prometheusNodeExporterServerCrt;
  keySecret = config.sops.secrets.prometheusNodeExporterServerKey;
  webConfig = (pkgs.formats.yaml { }).generate "node-exporter-web-config.yaml" {
    tls_server_config = {
      cert_file = certificateSecret.path;
      key_file = keySecret.path;
      client_auth_type = "RequireAndVerifyClientCert";
      client_ca_file = cfg.mtls.trustedCaCertificate;
    };
  };
in
{
  options.host.observability.client.nodeExporter = {
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

    mtls = {
      enable = lib.mkEnableOption "mTLS protection for the Prometheus node exporter";

      secretPrefix = lib.mkOption {
        type = lib.types.str;
        default = "prometheus/node_exporter";
        description = "Secret prefix containing the node exporter server certificate and key.";
      };

      trustedCaCertificate = lib.mkOption {
        type = lib.types.path;
        default = config.host.internalPki.rootCaCertificate;
        description = "CA bundle used to authenticate node exporter clients.";
      };
    };
  };

  config = lib.mkIf (clientCfg.enable && cfg.mtls.enable) {
    sops.secrets = {
      prometheusNodeExporterServerCrt = {
        key = "${cfg.mtls.secretPrefix}/server_crt_unencrypted";
        owner = cfg.serviceUser;
        group = cfg.serviceGroup;
        mode = "0400";
      };

      prometheusNodeExporterServerKey = {
        key = "${cfg.mtls.secretPrefix}/server_key";
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
