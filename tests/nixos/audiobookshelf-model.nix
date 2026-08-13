{ pkgs, ... }:
let
  inherit (pkgs) lib;
  config.host = {
    audiobookshelf = {
      sso.application = "listener";
      libraries = {
        spoken = {
          source = "spoken";
          displayName = "Spoken books";
          provider = "audible";
          icon = "audiobookshelf";
          access = "readOnly";
        };
        ebooks = {
          source = "written";
          displayName = "Written books";
          provider = "google";
          icon = "book";
          access = "readWrite";
        };
      };
    };
    media.libraries = {
      spoken = {
        contentType = "audiobooks";
        storage = {
          claim = "archive";
          relativePath = "catalog/spoken";
        };
      };
      written = {
        contentType = "ebooks";
        storage = {
          claim = "archive";
          relativePath = "catalog/written";
        };
      };
    };
    storage.claims.archive.mountPoint = "/srv/archive";
    sso = {
      applications.listener = {
        adminGroup = "listener-admins";
        userGroup = "listener-users";
      };
      oidc = {
        baseScopes = [ "openid" ];
        clients.audiobookshelf.clientId = "audiobookshelf";
      };
    };
    web.services.audiobookshelf.public.url = "https://listen.example.test";
  };
  model = import ../../nixos/_mixins/audiobookshelf/model.nix { inherit config lib; };
in
assert model.libraries.spoken.media.path == "/srv/archive/catalog/spoken";
assert model.libraries.spoken.access == "readOnly";
assert model.libraries.ebooks.media.path == "/srv/archive/catalog/written";
assert model.libraries.ebooks.media.contentType == "ebooks";
assert model.libraries.ebooks.access == "readWrite";
assert model.ssoApplication.adminGroup == "listener-admins";
assert model.service.public.url == "https://listen.example.test";
pkgs.runCommand "audiobookshelf-model-test" { } ''
  touch "$out"
''
