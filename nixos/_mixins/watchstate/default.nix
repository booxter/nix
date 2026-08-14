{
  config,
  lib,
  ...
}:
let
  cfg = config.host.watchstate;
  jellyfin = config.host.jellyfin;
  libraryPath = if jellyfin == null then null else "${jellyfin.media.mountPoint}/library";
  absolutePath = lib.types.strMatching "^/.*";
  imagePin = import ./image-pin.nix;
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

    container = import ../../_lib/oci-image-options.nix {
      inherit lib;
      pin = imagePin;
    };

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
        default = libraryPath;
        readOnly = true;
        internal = true;
        description = "Host media-library path exposed read-only to WatchState.";
      };

      mountPoint = lib.mkOption {
        type = with lib.types; nullOr absolutePath;
        default = libraryPath;
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
