{
  host.houndarr = {
    enable = true;
    stateDir = "/data/.state/nixarr/houndarr";
    instances = {
      lidarr.api = "lidarr";
      radarr.api = "radarr";
      sonarr.api = "sonarr";
    };
  };
}
