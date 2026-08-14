{ config, ... }:
{
  host.aurral = {
    stateDir = "/data/.state/nixarr/aurral";
    flowDir = "${config.host.storage.claims.media.mountPoint}/library/flows";
    slskd = {
      enable = true;
      instance = "music";
      priority = 10;
      preferredFormat = "flac";
      strictFormat = false;
      cleanupAfterRuns = true;
    };
    publicHostName = "mu.${config.host.network.publicDomain}";
    authProxy.adminGroups = [ "media-admins" ];
  };

  host.slskd.instances.music = {
    enable = true;
    stateDir = "/var/lib/slskd";
    secretPrefix = "slskd";
    storage = {
      claim = "media";
      relativePath = "slskd";
    };
    api.port = 5030;
    vpn = {
      namespace = "wg";
      peerPort = 13869;
    };
  };
}
