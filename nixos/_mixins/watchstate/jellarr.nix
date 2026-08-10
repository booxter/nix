{
  config,
  lib,
  ...
}:
let
  cfg = config.host.watchstate;
in
{
  config = lib.mkIf cfg.enable {
    host.jellyfin.declarativeConfig.plugins = [
      {
        name = "Webhook";
        configuration.GenericOptions = [
          {
            WebhookName = "WatchState Global Webhook";
            WebhookUri = "${cfg.localUrl}/v1/api/webhook";
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
