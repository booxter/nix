{ config, ... }:
{
  host.aurral = {
    stateDir = "/data/.state/nixarr/aurral";
    storageClaim = "media";
    libraryRoots = [ "/data/media/library/music" ];
    publicHostName = "mu.${config.host.network.publicDomain}";
  };
}
