{
  host.houndarr = {
    enable = true;
    stateDir = "/data/.state/nixarr/houndarr";
    authProxy.gate = "srvarr-admin-apps";
    instances = {
      lidarr.api = "lidarr";
      radarr.api = "radarr";
      sonarr.api = "sonarr";
    };
  };
}
