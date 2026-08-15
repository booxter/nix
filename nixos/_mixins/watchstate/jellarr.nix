{
  lib,
  watchstateModel,
  ...
}:
let
  inherit (watchstateModel) cfg localUrl;
in
{
  config = lib.mkIf (cfg != null) {
    host.jellyfinDeclarativeConfig.plugins = [
      {
        name = "Webhook";
        configuration.GenericOptions = [
          {
            WebhookName = "WatchState Global Webhook";
            WebhookUri = "${localUrl}/v1/api/webhook";
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
