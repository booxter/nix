{
  config,
  lib,
  ...
}:
let
  cfg = config.host.observability;
  nodeCfg = config.services.prometheus.exporters.node;
  textfileDir = cfg.nodeExporter.textfile.directory;
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

    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = cfg.nodeExporter.listenAddress;
      disabledCollectors = lib.mkIf config.host.observability.thermal.enable [ "thermal" ];
      extraFlags = [
        "--collector.textfile"
        "--collector.textfile.directory=${textfileDir}"
      ];
    };

    # Work around nix-darwin node-exporter flag joining while still letting
    # nix-darwin generate the wait4path wrapper from launchd.command.
    launchd.daemons.prometheus-node-exporter.command = lib.mkForce "${lib.getExe nodeCfg.package} ${nodeExporterArgs}";

    system.activationScripts.launchd.text = lib.mkBefore ''
      mkdir -p ${textfileDir}
      chown root:wheel ${textfileDir}
      chmod 0755 ${textfileDir}
    '';
  };
}
