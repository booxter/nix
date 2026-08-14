{
  config,
  lib,
  pkgs,
  ...
}:
let
  override = config.host.observability.lanWan.wanEgressOverride;
  textfileDir = config.host.observability.nodeExporter.textfile.directories.default;
  exporter = pkgs.callPackage ./pkgs/lan-wan-exporter { };
  exportCommand = [
    (lib.getExe exporter)
    "--output"
    "${textfileDir}/lan-wan.prom"
  ]
  ++ lib.optionals (override != null) [
    "--wan-subclass"
    override.name
    "--interface"
    override.interface
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
