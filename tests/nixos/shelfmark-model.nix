{ pkgs, ... }:
let
  inherit (pkgs) lib;
  config.host = {
    shelfmark = {
      libraries = {
        ebooks = "reading";
        audiobooks = "spoken";
      };
      downloaders = {
        torrent.route = "torrent-requests";
        usenet.route = "usenet-requests";
      };
      links.audiobookLibraryService = "listener";
      sso.application = "reader";
    };
    media.libraries = {
      reading = {
        contentType = "ebooks";
        storage = {
          claim = "archive";
          relativePath = "catalog/reading";
        };
      };
      spoken = {
        contentType = "audiobooks";
        storage = {
          claim = "archive";
          relativePath = "catalog/spoken";
        };
      };
    };
    storage.claims.archive.mountPoint = "/srv/archive";
    downloads = {
      clients = {
        torrent-client = {
          kind = "torrent";
          implementation = "transmission";
        };
        usenet-client = {
          kind = "usenet";
          implementation = "sabnzbd";
        };
      };
      routes = {
        torrent-requests = {
          client = "torrent-client";
          storage = {
            claim = "archive";
            relativePath = "incoming/torrent";
          };
        };
        usenet-requests = {
          client = "usenet-client";
          storage = {
            claim = "archive";
            relativePath = "incoming/usenet";
          };
        };
      };
    };
    sso = {
      applications.reader = {
        adminGroup = "reader-admins";
        userGroup = "reader-users";
      };
      oidc = {
        baseScopes = [ "openid" ];
        clients.shelfmark.clientId = "shelfmark";
      };
    };
    web.services = {
      shelfmark.public.url = "https://requests.example.test";
      listener.public.url = "https://listen.example.test";
    };
    ebookConverter = { };
  };
  model = import ../../nixos/_mixins/shelfmark/model.nix { inherit config lib; };
in
assert model.ebooks.path == "/srv/archive/catalog/reading";
assert model.audiobooks.path == "/srv/archive/catalog/spoken";
assert model.torrent.path == "/srv/archive/incoming/torrent";
assert model.usenet.path == "/srv/archive/incoming/usenet";
assert model.ssoApplication.adminGroup == "reader-admins";
assert model.audiobookLibraryService.public.url == "https://listen.example.test";
pkgs.runCommand "shelfmark-model-test" { } ''
  touch "$out"
''
