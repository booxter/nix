{ config, lib }:
lib.mapAttrs (
  _: library:
  library
  // {
    path = "${
      config.host.storage.claims.${library.storage.claim}.mountPoint
    }/${library.storage.relativePath}";
  }
) config.host.media.libraries
