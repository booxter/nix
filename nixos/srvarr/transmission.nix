{ ... }:
{
  host.transmission = {
    enable = true;
    stateDir = "/data/.state/nixarr/transmission";
    storage = {
      claim = "media";
      relativePath = "torrents";
    };
    vpn = {
      namespace = "wg";
      peerPort = 45486;
    };
    trackerPolicy = {
      enable = true;
      nonPreferred = {
        lowPriorityRatio = 3.0;
        pauseRatio = 6.0;
      };
    };
    torrentCleaner = {
      enable = true;
      minimumAgeDays = 30;
      maximumAgeDays = 365;
      schedule = "15m";
    };
  };
}
