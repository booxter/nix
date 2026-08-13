{ pkgs, ... }:
let
  inherit (pkgs) lib;
  config.host = {
    audiobookshelf = {
      sso.application = "listener";
      libraries.primary = {
        source = "spoken";
        displayName = "Spoken books";
        provider = "audible";
        icon = "audiobookshelf";
        access = "readOnly";
      };
    };
    media.libraries.spoken = {
      contentType = "audiobooks";
      storage = {
        claim = "archive";
        relativePath = "catalog/spoken";
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
assert model.libraries.primary.media.path == "/srv/archive/catalog/spoken";
assert model.libraries.primary.access == "readOnly";
assert model.ssoApplication.adminGroup == "listener-admins";
assert model.service.public.url == "https://listen.example.test";
pkgs.runCommand "audiobookshelf-model-test" { } ''
  touch "$out"
''
