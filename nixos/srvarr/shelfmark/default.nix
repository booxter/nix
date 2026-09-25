{ config, ... }:
{
  host.downloads.routes = {
    shelfmark-torrent = {
      client = "transmission";
      label = "shelfmark";
      storage = {
        claim = "media";
        relativePath = "torrents/shelfmark";
      };
    };
    shelfmark-usenet = {
      client = "sabnzbd";
      category = "shelfmark";
      storage = {
        claim = "media";
        relativePath = "usenet/shelfmark";
      };
    };
  };

  host.shelfmark = {
    stateDir = "/data/.state/nixarr/shelfmark";
    publicHostName = "shelf.${config.host.network.publicDomain}";
    libraries = {
      ebooks = "books";
      audiobooks = "audiobooks";
    };
    downloads = {
      torrent = "shelfmark-torrent";
      usenet = "shelfmark-usenet";
    };
  };

  services.shelfmark.environment = {
    # Keep multi-file ebook releases as separate Audiobookshelf items.
    FILE_ORGANIZATION = "rename";
    # The torrent and book directories are separate sandbox mounts.
    HARDLINK_TORRENTS = "false";
    # The torrent and audiobook directories are separate sandbox mounts.
    HARDLINK_TORRENTS_AUDIOBOOK = "false";
  };
}
