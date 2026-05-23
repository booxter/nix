{
  lib,
  pkgs,
  ...
}:
{
  environment.systemPackages = [
    pkgs.fleet-cache-warmer
  ];

  launchd.daemons.fleet-cache-warmer = {
    serviceConfig = {
      ProgramArguments = [
        (lib.getExe pkgs.fleet-cache-warmer)
      ];
      StartCalendarInterval = {
        Hour = 7;
        Minute = 30;
      };
      WorkingDirectory = "/var/root";
      EnvironmentVariables = {
        HOME = "/var/root";
      };
      ProcessType = "Background";
      StandardOutPath = "/var/log/fleet-cache-warmer.log";
      StandardErrorPath = "/var/log/fleet-cache-warmer.log";
    };
  };
}
