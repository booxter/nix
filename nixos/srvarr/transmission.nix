{ ... }:
{
  host.transmission = {
    enable = true;
    stateDir = "/data/.state/nixarr/transmission";
    dynamicIpUpdater = {
      enable = true;
      cookieJarFile = "/data/.secret/mam.cookies";
    };
    vpn = {
      namespace = "wg";
      peerPort = 45486;
    };
    trackerPolicy.enable = true;
    torrentCleaner = {
      enable = true;
    };
  };
}
