{ config, ... }:
let
  meilisearchPort = 7700;
  meilisearchUrl = "http://127.0.0.1:${toString meilisearchPort}";
  meilisearchMasterKeySecret = "meilisearch/masterKey";
in
{
  sops = {
    secrets.${meilisearchMasterKeySecret} = {
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
        MEILI_URL=${meilisearchUrl}
        MEILI_MASTER_KEY=${config.sops.placeholder.${meilisearchMasterKeySecret}}
      '';
      restartUnits = [ "jellyfin.service" ];
    };
  };

  services = {
    meilisearch = {
      enable = true;
      listenAddress = "127.0.0.1";
      listenPort = meilisearchPort;
      masterKeyFile = config.sops.secrets.${meilisearchMasterKeySecret}.path;
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
            Url = meilisearchUrl;
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
}
