{
  config,
  lib,
  pkgs,
  utils,
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
  exportCommand = utils.escapeSystemdExecArgs (
    [
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
    ]
  );
in
{
  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d ${textfileDir} 0755 root root - -" ];

    systemd.services.observability-lan-wan-export = {
      description = "Export LAN/WAN accounting metrics for node exporter";
      after = [ "observability-lan-wan-accounting.service" ];
      requires = [ "observability-lan-wan-accounting.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = exportCommand;
      };
    };

    systemd.timers.observability-lan-wan-export = {
      description = "Refresh LAN/WAN accounting metrics";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "15s";
        Unit = "observability-lan-wan-export.service";
      };
    };
  };
}
