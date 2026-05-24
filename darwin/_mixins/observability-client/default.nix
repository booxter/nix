{ config, lib, ... }:
let
  cfg = config.host.observability.client;
  nodeExporterMtls = import ../../../lib/prometheus-node-exporter-mtls.nix;
in
{
  options.host.observability.client = {
    enable = lib.mkEnableOption "host-side observability client services";

    nodeExporter = {
      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = "Address for the Prometheus node exporter to bind.";
      };

      mtls.enable = lib.mkEnableOption "mTLS protection for the Prometheus node exporter";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        services.prometheus.exporters.node = {
          enable = true;
          listenAddress = cfg.nodeExporter.listenAddress;
        };
      }
      (lib.mkIf cfg.nodeExporter.mtls.enable (
        let
          nodeExporterDaemon = config.launchd.daemons.prometheus-node-exporter.serviceConfig;
          nodeExporterUser = nodeExporterDaemon.UserName;
          nodeExporterGroup = nodeExporterDaemon.GroupName;
        in
        {
          sops.secrets.prometheusNodeExporterServerCrt = {
            key = "${nodeExporterMtls.nodeExporterSecretPrefix}/server_crt";
            owner = nodeExporterUser;
            group = nodeExporterGroup;
            mode = "0400";
          };

          sops.secrets.prometheusNodeExporterServerKey = {
            key = "${nodeExporterMtls.nodeExporterSecretPrefix}/server_key";
            owner = nodeExporterUser;
            group = nodeExporterGroup;
            mode = "0400";
          };

          sops.templates."node-exporter-web-config.yaml" = {
            owner = nodeExporterUser;
            group = nodeExporterGroup;
            mode = "0400";
            content = nodeExporterMtls.mkNodeExporterWebConfig {
              certFile = config.sops.secrets.prometheusNodeExporterServerCrt.path;
              keyFile = config.sops.secrets.prometheusNodeExporterServerKey.path;
            };
          };

          services.prometheus.exporters.node.extraFlags = [
            "--web.config.file=${config.sops.templates."node-exporter-web-config.yaml".path}"
          ];
        }
      ))
    ]
  );
}
