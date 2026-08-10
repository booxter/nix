{
  config,
  lib,
  outputs,
  ...
}:
let
  cfg = config.host.watchstate;
  model = import ./model.nix { inherit config outputs; };
in
{
  config = lib.mkIf cfg.enable {
    host.watchstate.jellyfin.declarativeConfig.plugins = [
      {
        name = "Webhook";
        configuration.GenericOptions = [
          {
            WebhookName = "WatchState Global Webhook";
            WebhookUri = model.webhookUrl;
            NotificationTypes = [
              "ItemAdded"
              "UserDataSaved"
              "PlaybackStart"
              "PlaybackStop"
            ];
            UserFilter = [ ];
            EnableMovies = true;
            EnableEpisodes = true;
            EnableSeries = false;
            EnableSeasons = false;
            EnableAlbums = false;
            EnableSongs = false;
            EnableVideos = false;
            SendAllProperties = true;
            TrimWhitespace = true;
            SkipEmptyMessageBody = true;
            EnableWebhook = true;
            Headers = [
              {
                Key = "Content-Type";
                Value = "application/json";
              }
            ];
            Fields = [ ];
          }
        ];
      }
    ];
  };
}
