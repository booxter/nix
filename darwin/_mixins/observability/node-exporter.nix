{
  config,
  lib,
  ...
}:
let
  cfg = config.host.observability;
  nodeCfg = config.services.prometheus.exporters.node;
  stateDir = "/var/lib/prometheus-node-exporter";
  textfileDirs = builtins.attrValues cfg.nodeExporter.textfile.directories;
  nodeExporterArgs = lib.escapeShellArgs (
    [
      "--web.listen-address"
      "${nodeCfg.listenAddress}:${toString nodeCfg.port}"
    ]
    ++ map (collector: "--collector.${collector}") nodeCfg.enabledCollectors
    ++ map (collector: "--no-collector.${collector}") nodeCfg.disabledCollectors
    ++ nodeCfg.extraFlags
  );
in
{
  config = lib.mkIf cfg.enable {
    host.observability.nodeExporter = {
      serviceUser = config.launchd.daemons.prometheus-node-exporter.serviceConfig.UserName;
      serviceGroup = config.launchd.daemons.prometheus-node-exporter.serviceConfig.GroupName;
    };
    host.launchd.logging.locations.prometheus-node-exporter = {
      directory = stateDir;
      collect = true;
      scope = "system";
    };

    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = cfg.nodeExporter.listenAddress;
      disabledCollectors = [ "thermal" ];
      extraFlags = [
        "--collector.textfile"
      ]
      ++ map (directory: "--collector.textfile.directory=${directory}") textfileDirs;
    };

    # Prepare service state without populating a macOS home skeleton.
    users.users._prometheus-node-exporter.createHome = lib.mkForce false;
    system.tmpfiles.settings.prometheus-node-exporter.${stateDir}.d = {
      mode = "0755";
      user = cfg.nodeExporter.serviceUser;
      group = cfg.nodeExporter.serviceGroup;
    };

    # Work around nix-darwin node-exporter flag joining while still letting
    # nix-darwin generate the wait4path wrapper from launchd.command.
    launchd.daemons.prometheus-node-exporter.command = lib.mkForce "${lib.getExe nodeCfg.package} ${nodeExporterArgs}";
  };
}
