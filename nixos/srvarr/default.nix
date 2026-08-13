{
  config,
  lib,
  pkgs,
  ...
}:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = "25.11";

  host.network = {
    interfaces.ens18.kind = "ethernet";
    macAddress = "bc:24:11:19:4d:d1";
    primaryInterface = "ens18";
    reservation = {
      enable = true;
      address = "192.168.20.2";
    };
  };

  host.ups.client.server = "prx1-lab";

  host.backups.destinations.primary = {
    server = "beast";
    publicKey = readPublicKey ./restic.pub;
  };

  _module.args.srvarrPkgs = import ./pkgs pkgs;

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

  host.ebookConverter = {
    enable = true;
    library = "books";
  };

  host.shelfmark = {
    enable = true;
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
    presentation.audiobookLibraryService = "audiobookshelf";
  };

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

  host.aurral = {
    enable = true;
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

  host.houndarr = {
    enable = true;
    stateDir = "/data/.state/nixarr/houndarr";
    authProxy.gate = "srvarr-admin-apps";
    instances = {
      lidarr.api = "lidarr";
      radarr.api = "radarr";
      sonarr.api = "sonarr";
    };
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

  imports = [
    ./arr.nix
    ./glance.nix
    ./letterboxd-list-radarr.nix
    ./lidarr-cue-splitter.nix
    ./oauth2-proxy.nix
    ./storage.nix
    ./pinepods.nix
    ./romm.nix
    ./qos.nix
    ./sabnzbd.nix
    ./seerr.nix
    ./tuning.nix
    ./transmission.nix
    ./vpn.nix
  ];
}
