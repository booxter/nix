{ config, lib, ... }:
let
  cfg = config.host.observability;
in
{
  options.host.observability.nodeExporter.openFirewall = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether to open the firewall for the Prometheus node exporter.";
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        host.observability.nodeExporter = {
          serviceUser = config.services.prometheus.exporters.node.user;
          serviceGroup = config.services.prometheus.exporters.node.group;
          textfile.directories.default = "/var/lib/prometheus-node-exporter-textfile";
        };

        services.prometheus.exporters.node = {
          enable = true;
          inherit (cfg.nodeExporter) listenAddress openFirewall;
          enabledCollectors = [
            "processes"
            "systemd"
            "textfile"
          ];
          extraFlags = map (directory: "--collector.textfile.directory=${directory}") (
            builtins.attrValues cfg.nodeExporter.textfile.directories
          );
        };

        systemd.tmpfiles.rules = map (directory: "d ${directory} 0755 root root - -") (
          builtins.attrValues cfg.nodeExporter.textfile.directories
        );
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
