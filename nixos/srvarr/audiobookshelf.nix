{ config, ... }:
{
  host.audiobookshelf = {
    enable = true;
    stateDir = "/data/.state/nixarr/audiobookshelf";
    publicHostName = "au.${config.host.network.publicDomain}";
    libraries.main = {
      source = "audiobooks";
      displayName = "Audiobooks";
      provider = "audible";
      icon = "audiobookshelf";
      access = "readWrite";
    };
  };
}
