{ config, lib }:
{
  resolved = lib.mapAttrs (
    name: library:
    let
      claim = config.host.storage.claims.${library.storage.claim} or null;
    in
    library
    // {
      inherit claim name;
      path = if claim == null then null else "${claim.mountPoint}/${library.storage.relativePath}";
    }
  ) config.host.media.libraries;
}
