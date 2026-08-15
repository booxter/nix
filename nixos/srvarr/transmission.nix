{ ... }:
{
  host.transmission = {
    stateDir = "/data/.state/nixarr/transmission";
    dynamicIpUpdater = {
      cookieJarFile = "/data/.secret/mam.cookies";
    };
    vpn = {
      peerPort = 45486;
    };
    trackerPolicy = { };
    torrentCleaner = { };
    uploadLimit.initialKBytesPerSecond = 950;
  };
}
