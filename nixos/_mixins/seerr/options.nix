{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.seerr;
  absolutePath = lib.types.strMatching "^/.*";
  servarrIntegration =
    kind:
    lib.types.submodule (
      { name, ... }:
      {
        options = {
          api = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = kind;
            description = "Registered host.web.api implementing ${kind}.";
          };
          displayName = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = name;
            description = "Instance name stored in Seerr.";
          };
          library = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "Registered media library used as the root folder.";
          };
          profile = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "Quality profile selected by name.";
          };
          default = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          availabilitySync = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          searchRequests = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          tagRequests = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
        }
        // lib.optionalAttrs (kind == "radarr") {
          minimumAvailability = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "released";
          };
        }
        // lib.optionalAttrs (kind == "sonarr") {
          seasonFolders = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          monitorNewItems = lib.mkOption {
            type = lib.types.enum [
              "all"
              "none"
            ];
            default = "all";
          };
        };
      }
    );
in
{
  options.host.seerr = {
    enable = lib.mkEnableOption "Seerr media request manager";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.seerr;
      description = "Seerr package to run and whose OpenAPI document generates the client.";
    };

    reconcilePackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package {
        seerr = cfg.package;
        seerr-api-go = pkgs.callPackage ../../../pkgs/seerr-api-go { seerr = cfg.package; };
      };
      description = "Seerr settings reconciliation package.";
    };

    maintenanceToolsPackage = lib.mkOption {
      type = with lib.types; nullOr package;
      default = null;
      description = "Optional Seerr maintenance commands installed on the service host.";
    };

    stateDir = lib.mkOption {
      type = absolutePath;
      default = "/var/lib/seerr";
    };

    publicHostName = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = null;
    };

    user = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "seerr";
      internal = true;
    };

    group = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "seerr";
      internal = true;
    };

    authentication.local.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Keep Seerr password login available.";
    };

    requestPolicy = {
      defaultPermissions = lib.mkOption {
        type = lib.types.listOf (
          lib.types.enum [
            "request"
            "auto-approve"
            "advanced-request"
          ]
        );
        default = [ "request" ];
      };
      partialRequests = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      specialEpisodes = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
    };

    integrations = {
      jellyfin = {
        host = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
          description = "NixOS host providing Jellyfin.";
        };
        authentication.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        libraries = lib.mkOption {
          type = with lib.types; listOf nonEmptyStr;
          default = [ ];
          description = "Explicit Jellyfin library keys enabled for availability scanning.";
        };
        apiKeySecret = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = "seerr/jellyfin/api_key";
        };
      };

      radarr = lib.mkOption {
        type = lib.types.attrsOf (servarrIntegration "radarr");
        default = { };
      };

      sonarr = lib.mkOption {
        type = lib.types.attrsOf (servarrIntegration "sonarr");
        default = { };
      };
    };

    metadata = {
      series = lib.mkOption {
        type = lib.types.enum [
          "tmdb"
          "tvdb"
        ];
        default = "tvdb";
      };
      anime = lib.mkOption {
        type = lib.types.enum [
          "tmdb"
          "tvdb"
        ];
        default = "tmdb";
      };
    };

    notifications.telegram = {
      enable = lib.mkEnableOption "Seerr Telegram notifications";
      secrets = {
        botApi = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = "seerr/telegram/bot_api";
        };
        botUsername = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = "seerr/telegram/bot_username";
        };
        chatId = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = "seerr/telegram/chat_id";
        };
        messageThreadId = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
        };
      };
      events = lib.mkOption {
        type = lib.types.listOf (
          lib.types.enum [
            "request-pending"
            "request-approved"
            "request-available"
            "request-failed"
            "request-declined"
            "request-auto-approved"
            "request-auto-created"
            "issue-created"
            "issue-commented"
            "issue-resolved"
            "issue-reopened"
          ]
        );
        default = [ ];
      };
      embedPoster = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      sendSilently = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
    };

    apiKeySecret = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "seerr/api_key";
    };

    backups.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
  };
}
