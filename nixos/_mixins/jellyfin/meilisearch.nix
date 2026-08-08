{
  config,
  lib,
  ...
}:
let
  jellyfinCfg = config.services.jellyfin;
  cfg = jellyfinCfg.meilisearch;
  url = "http://127.0.0.1:${toString cfg.port}";
  masterKeySecret = "meilisearch/masterKey";
in
{
  options.services.jellyfin.meilisearch = {
    enable = lib.mkEnableOption "Meilisearch-backed Jellyfin search";

    port = lib.mkOption {
      type = lib.types.port;
      default = 7700;
      description = "Loopback port on which Meilisearch listens.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = jellyfinCfg.enable && config.services.jellarr.enable;
        message = "services.jellyfin.meilisearch requires Jellyfin and Jellarr.";
      }
    ];

    sops = {
      secrets.${masterKeySecret} = {
        restartUnits = [
          "jellyfin.service"
          "meilisearch.service"
        ];
      };
      templates."jellyfin-meilisearch.env" = {
        owner = jellyfinCfg.user;
        group = jellyfinCfg.group;
        mode = "0400";
        content = ''
          MEILI_URL=${url}
          MEILI_MASTER_KEY=${config.sops.placeholder.${masterKeySecret}}
        '';
        restartUnits = [ "jellyfin.service" ];
      };
    };

    services = {
      meilisearch = {
        enable = true;
        listenAddress = "127.0.0.1";
        listenPort = cfg.port;
        masterKeyFile = config.sops.secrets.${masterKeySecret}.path;
        settings.env = "production";
      };

      jellarr.config = {
        system.pluginRepositories = [
          {
            name = "Meilisearch";
            url = "https://raw.githubusercontent.com/arnesacnussem/jellyfin-plugin-meilisearch/refs/heads/master/manifest.json";
            enabled = true;
          }
        ];
        plugins = [
          {
            name = "Meilisearch";
            configuration = {
              Url = url;
              MatchingStrategy = "all";
            };
          }
        ];
      };
    };

    systemd.services = {
      jellyfin = {
        wants = [ "meilisearch.service" ];
        after = [
          "meilisearch.service"
          "sops-install-secrets.service"
        ];
        serviceConfig.EnvironmentFile = config.sops.templates."jellyfin-meilisearch.env".path;
      };

      meilisearch = {
        wants = [ "sops-install-secrets.service" ];
        after = [ "sops-install-secrets.service" ];
      };
    };
  };
}
