{
  config,
  lib,
  ...
}:
let
  jellyfin = config.host.jellyfin;
  port = 7700;
  url = "http://127.0.0.1:${toString port}";
  masterKeySecret = "meilisearch/masterKey";
in
{
  config = lib.mkIf (jellyfin != null && jellyfin.meilisearch.enable) {
    sops = {
      secrets.${masterKeySecret} = {
        restartUnits = [
          "jellyfin.service"
          "meilisearch.service"
        ];
      };
      templates."jellyfin-meilisearch.env" = {
        owner = "jellyfin";
        group = "jellyfin";
        mode = "0400";
        content = ''
          MEILI_URL=${url}
          MEILI_MASTER_KEY=${config.sops.placeholder.${masterKeySecret}}
        '';
        restartUnits = [ "jellyfin.service" ];
      };
    };

    host.jellyfinDeclarativeConfig = {
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

    services.meilisearch = {
      enable = true;
      listenAddress = "127.0.0.1";
      listenPort = port;
      masterKeyFile = config.sops.secrets.${masterKeySecret}.path;
      settings.env = "production";
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
