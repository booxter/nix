{
  config,
  inputs,
  lib,
  ...
}:
let
  cfg = config.host.jellyfin;
  absolutePath = lib.types.strMatching "^/.*";
  openAttrs = lib.types.attrsOf lib.types.anything;
  libraryModule =
    { name, ... }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = name;
          description = "Jellyfin display name for the library.";
        };
        path = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = name;
          description = "Directory below the media resource's library root.";
        };
        kind = lib.mkOption {
          type = lib.types.enum [
            "movies"
            "series"
            "music"
          ];
          description = "Media kind determining Jellyfin collection and provider policy.";
        };
        audience = lib.mkOption {
          type = lib.types.enum [
            "general"
            "adult"
          ];
          default = "general";
        };
        metadataPolicy = lib.mkOption {
          type = lib.types.enum [
            "default"
            "tmdb-first"
          ];
          default = "default";
        };
      };
    };
  declarativeConfigModule = {
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
in
{
  imports = [
    inputs.jellarr.nixosModules.default
    ./assertions.nix
    ./backups.nix
    ./jellarr.nix
    ./maintenance.nix
    ./media.nix
    ./meilisearch.nix
    ./observability.nix
    ./service.nix
    ./web.nix
  ];

  options.host.jellyfin = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          media = {
            provider = lib.mkOption {
              type = lib.types.nonEmptyStr;
              default = config.networking.hostName;
              description = "Host providing Jellyfin's media storage resource.";
            };

            resource = lib.mkOption {
              type = lib.types.nonEmptyStr;
              default = "media";
              description = "Storage resource containing Jellyfin's media tree.";
            };

            mountPoint = lib.mkOption {
              type = absolutePath;
              default = "/media";
              description = "Stable path presented to Jellyfin and its consumers.";
            };
          };

          libraries = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule libraryModule);
            default = { };
            description = "Media libraries consumed by this Jellyfin installation.";
          };

          backups.stagingDirectory = lib.mkOption {
            type = with lib.types; nullOr absolutePath;
            default = null;
            description = "Directory where Jellyfin backup archives are staged for Restic.";
          };
        };
      }
    );
    default = null;
    description = "Jellyfin media server configuration.";
  };

  options.host.jellyfinDeclarativeConfig = lib.mkOption {
    type = lib.types.submodule declarativeConfigModule;
    default = { };
    internal = true;
    description = "Jellarr policy contributed by the Jellyfin host and its integrations.";
  };

  config = lib.mkIf (cfg != null) {
    host.autoUpgrade.claims.jellyfin.reboot = {
      cadence = "weekly";
      weekday = "Sat";
    };
  };
}
