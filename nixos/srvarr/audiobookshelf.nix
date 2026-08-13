{ config, ... }:
{
  host.audiobookshelf = {
    enable = true;
    stateDir = "/data/.state/nixarr/audiobookshelf";
    publicHostName = "au.${config.host.network.publicDomain}";
    libraries = {
      audiobooks = {
        source = "audiobooks";
        displayName = "Audiobooks";
        provider = "google";
        icon = "database";
        access = "readWrite";
      };
      books = {
        source = "books";
        displayName = "Books";
        provider = "google";
        icon = "database";
        access = "readWrite";
      };
    };
  };
}
