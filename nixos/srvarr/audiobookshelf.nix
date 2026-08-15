{ config, ... }:
{
  host.media.libraries = {
    books = {
      contentType = "ebooks";
      storage = {
        claim = "media";
        relativePath = "library/books";
      };
    };
    audiobooks = {
      contentType = "audiobooks";
      storage = {
        claim = "media";
        relativePath = "library/audiobooks";
      };
    };
  };

  host.audiobookshelf = {
    stateDir = "/data/.state/nixarr/audiobookshelf";
    publicHostName = "au.${config.host.network.publicDomain}";
    libraries = {
      audiobooks = {
        displayName = "Audiobooks";
      };
      books = {
        displayName = "Books";
      };
    };
  };
}
