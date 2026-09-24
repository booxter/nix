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
    torrentPolicy = { };
    uploadLimit.initialKBytesPerSecond = 950;
  };
}
