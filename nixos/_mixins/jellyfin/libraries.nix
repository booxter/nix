{ lib, ... }:
{
  options.services.jellyfin.libraries = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Display name of the Jellyfin library.";
          };

          path = lib.mkOption {
            type = lib.types.str;
            description = "Path beneath the media library root.";
          };

          collectionType = lib.mkOption {
            type = lib.types.str;
            description = "Jellyfin collection type.";
          };

          isAdult = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether to use adult-content metadata providers.";
          };

          preferTmdb = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether TMDB should precede adult-content metadata providers.";
          };
        };
      }
    );
    default = [ ];
    description = "Media libraries managed by Jellyfin and its storage provider.";
  };
}
