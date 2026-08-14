{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.thermal;
  thermalExporter = pkgs.callPackage ./pkgs/thermal-exporter { };
  ismc = pkgs.callPackage ./pkgs/ismc { };
  textfileDir = "/var/lib/observability-thermal/textfile";
in
{
  options.host.observability.thermal.enable =
    lib.mkEnableOption "Darwin thermal and power metrics export";

  config = lib.mkMerge [
    {
      host.observability.thermal.enable = lib.mkDefault config.host.observability.enable;
    }
    (lib.mkIf cfg.enable {
      environment.systemPackages = [ ismc ];

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
          (lib.getExe ismc)
          "--textfile-directory"
          textfileDir
        ];
        serviceConfig = {
          RunAtLoad = true;
          StartInterval = 30;
          StandardOutPath = "/var/log/observability-thermal-export.log";
          StandardErrorPath = "/var/log/observability-thermal-export.log";
        };
      };
    })
  ];
}
