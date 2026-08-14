{
  lib,
  pkgs,
  ...
}:
let
  libraryType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        source = lib.mkOption {
          type = lib.types.nonEmptyStr;
          description = "Registered media library exposed as ${name} in Audiobookshelf.";
        };

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
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.audiobookshelf;
        description = "Audiobookshelf package to run.";
      };

      reconcilePackage = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./package { };
        description = "Audiobookshelf settings reconciliation package.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 9292;
      };

      stateDir = lib.mkOption {
        type = lib.types.strMatching "^/.*";
        default = "/var/lib/audiobookshelf";
      };

      publicHostName = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Public hostname published for Audiobookshelf.";
      };

      libraries = lib.mkOption {
        type = lib.types.attrsOf libraryType;
        default = { };
        description = "Registered media libraries managed by Audiobookshelf.";
      };

      sso.application = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "audiobookshelf";
        description = "Realm SSO application controlling Audiobookshelf access.";
      };

      automation.secret = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "audiobookshelf/bootstrap/api_token";
        description = "SOPS key containing an Audiobookshelf automation credential.";
      };

      backups = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };

        schedule = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = "15 4 * * *";
        };

        keep = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 2;
        };

        maxSizeGiB = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 1;
        };
      };

      user = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "audiobookshelf";
        internal = true;
      };

      group = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "media";
        internal = true;
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
