{ config, lib, ... }:
let
  cfg = config.host.jellyfin;
  libraryDirectories = builtins.listToAttrs (
    map (library: {
      name = "library/${library.path}";
      value = { };
    }) (builtins.attrValues cfg.libraries)
  );
in
{
  config = lib.mkIf cfg.enable {
    host.storage.claims.jellyfin-media = {
      inherit (cfg.media) provider resource mountPoint;
      directories = {
        library = { };
      }
      // libraryDirectories;
    };
  };
}
