{ lib, ... }:
let
  libraryType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        displayName = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = name;
          description = "Library name displayed by Audiobookshelf.";
        };

        provider = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = "google";
          description = "Audiobookshelf metadata provider for the library.";
        };

        icon = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = "database";
          description = "Audiobookshelf library icon.";
        };

        access = lib.mkOption {
          type = lib.types.enum [
            "readOnly"
            "readWrite"
          ];
          default = "readWrite";
          description = "Filesystem access Audiobookshelf receives to the library.";
        };
      };
    }
  );
  configType = lib.types.submodule {
    options = {
      stateDir = lib.mkOption {
        type = lib.types.strMatching "^/.*";
        default = "/var/lib/audiobookshelf";
      };

      publicHostName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Public hostname published for Audiobookshelf.";
      };

      libraries = lib.mkOption {
        type = lib.types.addCheck (lib.types.attrsOf libraryType) (libraries: libraries != { });
        description = "Registered media libraries managed by Audiobookshelf.";
      };

    };
  };
in
{
  options.host.audiobookshelf = lib.mkOption {
    type = with lib.types; nullOr configType;
    default = null;
    description = "Audiobookshelf audiobook and ebook server.";
  };
}
