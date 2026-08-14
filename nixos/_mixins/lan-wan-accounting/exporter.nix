{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.lanWan;
  egressOverrideEnabled = cfg.wanEgressOverride != null;
  tableName = "observability_lan_wan";
  textfileDir = config.host.observability.nodeExporter.textfile.directories.default;
  exporter = pkgs.callPackage ./pkgs/lan-wan-exporter { };
  override = cfg.wanEgressOverride;
  exportCommand = [
    (lib.getExe exporter)
    "--table"
    tableName
    "--output"
    "${textfileDir}/lan-wan.prom"
  ]
  ++ lib.optionals egressOverrideEnabled [
    "--wan-subclass"
    override.name
    "--interface"
    config.host.network.primaryInterface
    "--wan-tc-class"
    override.tcClass
  ];
in
{
  config = lib.mkIf config.host.observability.enable {
    host.observability.nodeExporter.textfile.periodicProducers.observability-lan-wan-export = {
      description = "Export LAN/WAN accounting metrics for node exporter";
      after = [ "observability-lan-wan-accounting.service" ];
      requires = [ "observability-lan-wan-accounting.service" ];
      command = exportCommand;
      interval = "15s";
      onBootSec = "30s";
      addressFamilies = [
        "AF_UNIX"
        "AF_NETLINK"
      ];
    };
  };
}
