{
  config,
  lib,
  ...
}:
let
  cfg = config.host.media.libraries;
in
{
  options.host.media.libraries = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            contentType = lib.mkOption {
              type = lib.types.enum [
                "ebooks"
                "audiobooks"
              ];
              description = "Content stored in the ${name} media library.";
            };

            storage = {
              claim = lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "Storage claim containing the ${name} media library.";
              };

              relativePath = lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "Path to the ${name} media library below its storage claim.";
              };
            };
          };
        }
      )
    );
    default = { };
    description = "Semantic media libraries shared by host-local services.";
  };

  config.host.storage.claims = lib.mkMerge (
    lib.mapAttrsToList (_: library: {
      ${library.storage.claim}.directories.${library.storage.relativePath} = { };
    }) cfg
  );
}
