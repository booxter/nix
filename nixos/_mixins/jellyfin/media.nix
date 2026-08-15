{ config, lib, ... }:
let
  cfg = config.host.jellyfin;
  libraryDirectories = builtins.listToAttrs (
    map (library: {
      name = "library/${library.path}";
      value = { };
    }) (if cfg == null then [ ] else builtins.attrValues cfg.libraries)
  );
in
{
  config = lib.mkIf (cfg != null) {
    host.storage.claims.jellyfin-media = {
      inherit (cfg.media) provider resource mountPoint;
      directories = {
        library = { };
      }
      // libraryDirectories;
    };
  };
}
