{
  config,
  lib,
  pkgs,
  ...
}:
let
  darwinPkgs = import ../../pkgs pkgs;
  cfg = config.host.observability.thermal;
  thermalExporter = pkgs.callPackage ./pkgs/thermal-exporter { };
in
{
  options.host.observability.thermal = {
    enable = lib.mkEnableOption "Darwin thermal and power metrics export";

    package = lib.mkOption {
      type = lib.types.package;
      default = darwinPkgs.ismc;
      description = "iSMC package used to collect Darwin temperature sensors.";
    };

    intervalSeconds = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "How often to sample Darwin thermal state and power metrics.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    assertions = [
      {
        assertion = config.host.observability.lanWan.enable;
        message = "Darwin thermal export currently requires host.observability.lanWan.enable so node exporter textfile support is configured.";
      }
    ];

    launchd.daemons.observability-thermal-export.serviceConfig = {
      ProgramArguments = [
        (lib.getExe thermalExporter)
        "--ismc"
        (lib.getExe cfg.package)
      ];
      RunAtLoad = true;
      StartInterval = cfg.intervalSeconds;
      StandardOutPath = "/var/log/observability-thermal-export.log";
      StandardErrorPath = "/var/log/observability-thermal-export.log";
    };
  };
}
