{ pkgs, ... }:
let
  inherit (pkgs) lib;
  config.host = {
    storage.claims.archive.mountPoint = "/srv/archive";
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
    downloads = {
      clients.fetcher = {
        kind = "torrent";
        implementation = "transmission";
        endpoint = "http://127.0.0.1:18080/rpc";
      };
      routes.requests = {
        client = "fetcher";
        label = "requests";
        category = null;
        storage = {
          claim = "archive";
          relativePath = "incoming/requests";
        };
      };
    };
  };
  mediaModel = import ../../nixos/_mixins/media-libraries/model.nix { inherit config lib; };
  downloadModel = import ../../nixos/_mixins/downloads/model.nix { inherit config lib; };
in
assert mediaModel.resolved.reading.path == "/srv/archive/catalog/reading";
assert mediaModel.resolved.spoken.path == "/srv/archive/catalog/spoken";
assert downloadModel.routes.requests.clientName == "fetcher";
assert downloadModel.routes.requests.client.kind == "torrent";
assert downloadModel.routes.requests.path == "/srv/archive/incoming/requests";
pkgs.runCommand "media-acquisition-model-test" { } ''
  touch "$out"
''
