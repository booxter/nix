{ config, lib, ... }:
let
  cfg = config.host.observability;
  serverEnabled = cfg.server != null;
in
{
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
          listenAddress = if serverEnabled then "127.0.0.1" else cfg.nodeExporter.listenAddress;
          openFirewall = !serverEnabled;
          enabledCollectors = [
            "processes"
            "systemd"
            "textfile"
          ];
          extraFlags = map (directory: "--collector.textfile.directory=${directory}") (
            builtins.attrValues cfg.nodeExporter.textfile.directories
          );
        };

        systemd.tmpfiles.rules = [
          "d ${cfg.nodeExporter.textfile.directories.default} 0755 root root - -"
        ];
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
