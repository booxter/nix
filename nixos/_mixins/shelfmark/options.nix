{
  lib,
  pkgs,
  ...
}:
let
  configType = lib.types.submodule {
    options = {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.shelfmark;
        description = "Shelfmark package to run.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8084;
      };

      stateDir = lib.mkOption {
        type = lib.types.strMatching "^/.*";
        default = "/var/lib/shelfmark";
      };

      publicHostName = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Public hostname published for Shelfmark.";
      };

      libraries = {
        ebooks = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
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

      integrations.ebookConverter.enable = lib.mkEnableOption "the ebook converter hook";

      nav.audiobookshelf = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Public Audiobookshelf web service linked from Shelfmark navigation.";
      };

      sso.application = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "shelfmark";
        description = "Realm SSO application controlling Shelfmark access.";
      };

      backups.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };

      user = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "shelfmark";
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
  options.host.shelfmark = lib.mkOption {
    type = with lib.types; nullOr configType;
    default = null;
    description = "Shelfmark book request service.";
  };
}
