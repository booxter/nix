{ config, ... }:
{
  imports = [ ./ebook-converter.nix ];

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
    downloaders = {
      torrent.route = "shelfmark-torrent";
      usenet.route = "shelfmark-usenet";
    };
    integrations.ebookConverter.enable = true;
    nav.audiobookshelf = "audiobookshelf";
  };
}
