{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.thermal;
  thermalExporter = pkgs.callPackage ./pkgs/thermal-exporter { };
  textfileDir = "/var/lib/observability-thermal/textfile";
in
{
  options.host.observability.thermal = {
    enable = lib.mkEnableOption "Darwin thermal and power metrics export";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./pkgs/ismc { };
      description = "iSMC package used to collect Darwin temperature sensors.";
    };

    intervalSeconds = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "How often to sample Darwin thermal state and power metrics.";
    };
  };

  config = lib.mkMerge [
    {
      host.observability.thermal.enable = lib.mkDefault config.host.observability.enable;
    }
    (lib.mkIf cfg.enable {
      environment.systemPackages = [ cfg.package ];

      host.observability.nodeExporter.textfile.directories.thermal = textfileDir;

      system.activationScripts.launchd.text = lib.mkAfter ''
        mkdir -p ${textfileDir}
        chown root:wheel ${textfileDir}
        chmod 0755 ${textfileDir}
      '';

      launchd.daemons.observability-thermal-export = {
        command = lib.escapeShellArgs [
          (lib.getExe thermalExporter)
          "--ismc"
          (lib.getExe cfg.package)
          "--textfile-directory"
          textfileDir
        ];
        serviceConfig = {
          RunAtLoad = true;
          StartInterval = cfg.intervalSeconds;
          StandardOutPath = "/var/log/observability-thermal-export.log";
          StandardErrorPath = "/var/log/observability-thermal-export.log";
        };
      };
    })
  ];
}
