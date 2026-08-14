{ config, ... }:
{
  host.aurral = {
    stateDir = "/data/.state/nixarr/aurral";
    storageClaim = "media";
    slskd = {
      vpnNamespace = "wg";
      peerPort = 13869;
    };
    publicHostName = "mu.${config.host.network.publicDomain}";
  };
}
