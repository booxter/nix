{
  config,
  lib,
  pkgs,
  ...
}:
let
  thermalExporter = pkgs.callPackage ./pkgs/thermal-exporter { };
  ismc = pkgs.callPackage ./pkgs/ismc { };
  textfileDir = "/var/lib/observability-thermal/textfile";
in
{
  config = lib.mkIf config.host.observability.enable {
    environment.systemPackages = [ ismc ];

    host.observability.nodeExporter.textfile.directories.thermal = textfileDir;

    system.tmpfiles.settings.thermal.${textfileDir}.d = {
      mode = "0755";
      user = "root";
      group = "wheel";
    };

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
        StandardOutPath = "/var/log/nix-darwin/observability-thermal-export.log";
        StandardErrorPath = "/var/log/nix-darwin/observability-thermal-export.log";
      };
    };
  };
}
