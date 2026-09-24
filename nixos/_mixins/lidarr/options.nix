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
    apply = {
      enable = lib.mkEnableOption "automatic application of Lidarr repairs";
      allowedActions = lib.mkOption {
        type = with lib.types; listOf (enum [ "import_missing_tracks_v1" ]);
        default = [ ];
        description = "Repair actions the automatic controller may apply.";
      };
      allowedSources = lib.mkOption {
        type =
          with lib.types;
          listOf (enum [
            "tar_audio_v1"
            "directory_audio_v1"
          ]);
        default = [ ];
        description = "Evidence sources the automatic controller may apply repairs from.";
      };
    };
  };
}
