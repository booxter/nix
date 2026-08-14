{ lib, ... }:
let
  configType = lib.types.submodule {
    options = {
      stateDir = lib.mkOption {
        type = lib.types.strMatching "^/.*";
        default = "/var/lib/shelfmark";
      };

      publicHostName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Public hostname published for Shelfmark.";
      };

      libraries = {
        ebooks = lib.mkOption {
          type = lib.types.nonEmptyStr;
          description = "Registered ebook library receiving Shelfmark downloads.";
        };
        audiobooks = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
          description = "Registered audiobook library receiving Shelfmark downloads.";
        };
      };

      downloaders = {
        torrent.route = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
          description = "Selected torrent download route.";
        };
        usenet.route = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
          description = "Selected usenet download route.";
        };
      };

      nav.audiobookshelf = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Public Audiobookshelf web service linked from Shelfmark navigation.";
      };

    };
  };
in
{
  options.host.shelfmark = lib.mkOption {
    type = with lib.types; nullOr configType;
    default = null;
    description = "Shelfmark book request service.";
  };
}
