{ lib, ... }:
let
  openAttrs = lib.types.attrsOf lib.types.anything;
in
{
  options.host.jellyfin.declarativeConfig = lib.mkOption {
    type = lib.types.submodule {
      freeformType = openAttrs;
      options = {
        system = lib.mkOption {
          type = lib.types.submodule {
            freeformType = openAttrs;
            options.pluginRepositories = lib.mkOption {
              type = lib.types.listOf openAttrs;
              default = [ ];
            };
          };
          default = { };
        };
        library.virtualFolders = lib.mkOption {
          type = lib.types.listOf openAttrs;
          default = [ ];
        };
        users = lib.mkOption {
          type = lib.types.listOf openAttrs;
          default = [ ];
        };
        plugins = lib.mkOption {
          type = lib.types.listOf openAttrs;
          default = [ ];
        };
      };
    };
    default = { };
    description = "Jellarr policy contributed by the Jellyfin host and its integrations.";
  };
}
