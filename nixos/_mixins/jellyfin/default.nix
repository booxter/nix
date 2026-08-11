{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.jellyfin;
  absolutePath = lib.types.strMatching "^/.*";
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
in
{
  imports = [
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

  options.host.jellyfin = {
    enable = lib.mkEnableOption "Jellyfin media server";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.jellyfin;
      description = "Jellyfin package to run.";
    };

    localUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8096";
      readOnly = true;
      internal = true;
      description = "Loopback Jellyfin API URL.";
    };

    publicUrl = lib.mkOption {
      type = with lib.types; nullOr str;
      default = if cfg.enable then config.host.web.services.jellyfin.public.url else null;
      readOnly = true;
      internal = true;
      description = "Resolved public Jellyfin URL.";
    };

    apiKeyFile = lib.mkOption {
      type = with lib.types; nullOr absolutePath;
      default = if cfg.enable then config.sops.secrets."jellyfin/apiKey".path else null;
      readOnly = true;
      internal = true;
      description = "File containing the Jellyfin API key.";
    };

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

    meilisearch.enable = lib.mkEnableOption "Meilisearch-backed Jellyfin search";

    web = {
      public.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to publish Jellyfin through realm ingress.";
      };

      public.hostName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "jf.${config.host.network.publicDomain}";
        description = "Public Jellyfin hostname.";
      };

      transport = lib.mkOption {
        type = lib.types.enum [
          "internal-mtls"
          "direct"
        ];
        default = if config.host.web.ingress.enable then "direct" else "internal-mtls";
        description = "Transport used by realm ingress to reach Jellyfin.";
      };
    };

    backups = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to capture Jellyfin's built-in backup archives.";
      };

      stagingDirectory = lib.mkOption {
        type = with lib.types; nullOr absolutePath;
        default = null;
        description = "Directory where Jellyfin backup archives are staged for Restic.";
      };
    };

    maintenance.guardPlayback = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether disruptive maintenance waits for Jellyfin playback to stop.";
    };

    observability = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to run and scrape the Jellyfin exporter.";
      };

      internalPort = lib.mkOption {
        type = lib.types.port;
        default = 19594;
        description = "Loopback port where the Jellyfin exporter listens.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 9594;
        description = "mTLS port exposing Jellyfin metrics to Prometheus.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    host.autoUpgrade.claims.jellyfin.reboot = {
      cadence = "weekly";
      weekday = "Sat";
    };
  };
}
