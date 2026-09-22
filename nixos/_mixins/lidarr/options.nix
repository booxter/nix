{ lib, pkgs }:
{
  repair.controller = {
    enable = lib.mkEnableOption "scheduled shadow-mode Lidarr repair controller";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.lidarr-repair;
      description = "Lidarr repair controller package.";
    };
    interval = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "15m";
      description = "Delay between completed queue observations.";
    };
    requestTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Maximum duration of one Lidarr queue request.";
    };
  };
}
