{
  config,
  lib,
  pkgs,
  ...
}:
let
  model = import ./model.nix { inherit config; };
  inherit (model)
    cfg
    egressOverrideEnabled
    tableName
    textfileDir
    ;
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
    cfg.interface
    "--wan-tc-class"
    override.tcClass
  ];
in
{
  config = lib.mkIf cfg.enable {
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
