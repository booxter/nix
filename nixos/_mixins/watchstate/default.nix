{
  config,
  lib,
  ...
}:
let
  cfg = config.host.watchstate;
  absolutePath = lib.types.strMatching "^/.*";
in
{
  imports = [
    ./assertions.nix
    ./auth.nix
    ./backups.nix
    ./jellarr.nix
    ./service.nix
    ./web.nix
  ];

  options.host.watchstate = {
    enable = lib.mkEnableOption "WatchState media synchronization service";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Loopback port where WatchState listens.";
    };

    localUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:${toString cfg.port}";
      readOnly = true;
      internal = true;
      description = "Loopback WatchState API URL.";
    };

    dataDirectory = lib.mkOption {
      type = absolutePath;
      default = "/var/lib/watchstate";
      description = "Persistent WatchState state directory.";
    };

    library = {
      source = lib.mkOption {
        type = with lib.types; nullOr absolutePath;
        default = "${config.host.jellyfin.media.mountPoint}/library";
        readOnly = true;
        internal = true;
        description = "Host media-library path exposed read-only to WatchState.";
      };

      mountPoint = lib.mkOption {
        type = absolutePath;
        default = "${config.host.jellyfin.media.mountPoint}/library";
        readOnly = true;
        internal = true;
        description = "WatchState container path matching Jellyfin's media library.";
      };
    };

    backups = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to capture native WatchState backup archives.";
      };

      stagingDirectory = lib.mkOption {
        type = with lib.types; nullOr absolutePath;
        default = null;
        description = "Directory where WatchState archives are staged for Restic.";
      };
    };
  };
}
