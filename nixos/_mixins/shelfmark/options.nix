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

      downloads = {
        torrent = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
          description = "Selected torrent download route.";
        };
        usenet = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
          description = "Selected usenet download route.";
        };
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
