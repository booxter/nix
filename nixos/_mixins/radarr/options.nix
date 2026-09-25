{ lib, pkgs }:
{
  repair.controller = {
    enable = lib.mkEnableOption "scheduled Radarr repair controller";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.radarr-repair;
      description = "Radarr repair controller package.";
    };
    downloadClients = lib.mkOption {
      type = with lib.types; listOf nonEmptyStr;
      default = [ ];
      description = "Registered download clients inspected by the controller.";
    };
    interval = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "15m";
      description = "Delay between completed controller runs.";
    };
    stabilization = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "15m";
      description = "Minimum age of unchanged import-pending evidence before repair.";
    };
    metricsDirectory = lib.mkOption {
      type = lib.types.strMatching "^/.+";
      default = "/var/lib/prometheus-node-exporter-textfile/radarr-repair";
      readOnly = true;
      description = "Directory containing controller Prometheus textfile metrics.";
    };
    apply = {
      enable = lib.mkEnableOption "automatic application of Radarr repairs";
      allowedActions = lib.mkOption {
        type =
          with lib.types;
          listOf (enum [
            "join_parts_v1"
            "manual_import_file_v1"
            "remux_bluray_v1"
            "remux_dvd_v1"
          ]);
        default = [ ];
        description = "Repair actions the automatic controller may apply.";
      };
      allowedDownloadClients = lib.mkOption {
        type =
          with lib.types;
          listOf (enum [
            "transmission"
            "sabnzbd"
          ]);
        default = [ ];
        description = "Download clients whose cases the automatic controller may repair.";
      };
      finalizeStaleQueue = lib.mkEnableOption "safe removal of stale completed queue warnings";
    };
  };
}
