{ config, ... }:
{
  host.aurral = {
    stateDir = "/data/.state/nixarr/aurral";
    flowDir = "${config.host.storage.claims.media.mountPoint}/library/flows";
    slskd = {
      priority = 10;
      preferredFormat = "flac";
      strictFormat = false;
      cleanupAfterRuns = true;
      storage.claim = "media";
      vpn = {
        namespace = "wg";
        peerPort = 13869;
      };
    };
    publicHostName = "mu.${config.host.network.publicDomain}";
    authProxy.adminGroups = [ "media-admins" ];
  };
}
