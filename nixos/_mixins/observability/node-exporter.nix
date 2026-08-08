{ config, lib, ... }:
let
  cfg = config.host.observability;
in
{
  options.host.observability.nodeExporter = {
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to open the firewall for the Prometheus node exporter.";
    };

    textfile = {
      enable = lib.mkEnableOption "the node exporter textfile collector";

      directory = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/prometheus-node-exporter-textfile";
        description = "Directory read by the node exporter textfile collector.";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        host.observability.nodeExporter = {
          serviceUser = config.services.prometheus.exporters.node.user;
          serviceGroup = config.services.prometheus.exporters.node.group;
        };

        services.prometheus.exporters.node = {
          enable = true;
          inherit (cfg.nodeExporter) listenAddress openFirewall;
          enabledCollectors = [
            "processes"
            "systemd"
          ]
          ++ lib.optional cfg.nodeExporter.textfile.enable "textfile";
          extraFlags = lib.optional cfg.nodeExporter.textfile.enable "--collector.textfile.directory=${cfg.nodeExporter.textfile.directory}";
        };
      }
      (lib.mkIf cfg.nodeExporter.mtls.enable {
        sops.secrets = {
          prometheusNodeExporterServerCrt.restartUnits = [ "prometheus-node-exporter.service" ];
          prometheusNodeExporterServerKey.restartUnits = [ "prometheus-node-exporter.service" ];
        };

        systemd.services.prometheus-node-exporter = {
          wants = [ "sops-install-secrets.service" ];
          after = [ "sops-install-secrets.service" ];
        };
      })
    ]
  );
}
