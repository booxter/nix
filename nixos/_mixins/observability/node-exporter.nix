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

    textfile.directory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/prometheus-node-exporter-textfile";
      readOnly = true;
      internal = true;
      description = "Canonical node exporter textfile collector directory.";
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
            "textfile"
          ];
          extraFlags = [
            "--collector.textfile.directory=${cfg.nodeExporter.textfile.directory}"
          ];
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
