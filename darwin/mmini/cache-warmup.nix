{
  lib,
  pkgs,
  ...
}:
let
  mminiPkgs = import ./pkgs pkgs;
in
{
  environment.systemPackages = [
    mminiPkgs.fleet-cache-warmer
  ];

  launchd.daemons.fleet-cache-warmer = {
    serviceConfig = {
      ProgramArguments = [
        (lib.getExe mminiPkgs.fleet-cache-warmer)
      ];
      StartCalendarInterval = {
        Hour = 8;
        Minute = 30;
      };
      WorkingDirectory = "/var/root";
      EnvironmentVariables = {
        HOME = "/var/root";
        NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
        SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      };
      ProcessType = "Background";
      StandardOutPath = "/var/log/fleet-cache-warmer.log";
      StandardErrorPath = "/var/log/fleet-cache-warmer.log";
    };
  };
}
