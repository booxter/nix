{
  config,
  ...
}:
{
  host.seerr = {
    enable = true;
    stateDir = "/data/.state/nixarr/seerr";
    publicHostName = "js.${config.host.network.publicDomain}";
    authentication.local.enable = true;

    requestPolicy = {
      defaultPermissions = [
        "request"
        "auto-approve"
        "advanced-request"
      ];
      partialRequests = true;
      specialEpisodes = true;
    };

    integrations = {
      jellyfin = {
        host = "beast";
        authentication.enable = true;
        libraries = [
          "anime"
          "attic"
          "docu"
          "family"
          "fruit"
          "movies"
          "shows"
        ];
      };

      radarr.main = {
        api = "radarr";
        displayName = "localhost";
        library = "movies";
        profile = "Default HD";
        minimumAvailability = "released";
        default = true;
        availabilitySync = true;
        searchRequests = true;
        tagRequests = true;
      };

      sonarr.main = {
        api = "sonarr";
        displayName = "localhost";
        library = "shows";
        profile = "Default HD or Worse";
        default = true;
        availabilitySync = false;
        searchRequests = true;
        tagRequests = true;
        seasonFolders = false;
        monitorNewItems = "all";
      };
    };

    metadata = {
      series = "tvdb";
      anime = "tmdb";
    };

    notifications.telegram = {
      enable = true;
      events = [
        "request-pending"
        "request-approved"
        "request-available"
        "request-failed"
        "request-declined"
        "request-auto-approved"
        "issue-created"
        "issue-commented"
        "issue-resolved"
        "issue-reopened"
      ];
      embedPoster = true;
      sendSilently = true;
    };
  };
}
