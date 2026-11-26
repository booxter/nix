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
  config = lib.mkIf (jellyfin != null) {
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
      plugins = [
        {
          name = "Meilisearch";
          id = "974395db-b31d-46a2-bc86-ef9aa5ac04dd";
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
