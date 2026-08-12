{ config, lib, ... }:
let
  directories =
    paths: settings:
    builtins.listToAttrs (
      map (path: {
        name = path;
        value = settings;
      }) paths
    );
in
{
  options.host.srvarrPaths = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    readOnly = true;
    description = "Shared srvarr media and state root paths.";
  };

  config.host.srvarrPaths = {
    mediaDir = config.host.storage.claims.media.mountPoint;
    # Preserve the historical state root so backups and existing service state
    # continue to land in the same place.
    stateDir = "/data/.state/nixarr";
  };

  config.host.storage.claims.media = {
    provider = "beast";
    resource = "media";
    mountPoint = "/data/media";
    directories =
      directories [
        "library"
        "library/books"
        "library/audiobooks"
        "library/flows"
        "podcasts"
      ] { }
      // directories [ "podcasts/pinepods" ] { owner = "pinepods"; }
      // directories [
        "romm"
        "romm/assets"
        "romm/config"
        "romm/resources"
        "romm/sync"
        "romm/library"
        "romm/library/roms"
        "romm/library/roms/pc"
        "romm/library/bios"
      ] { owner = "romm"; }
      //
        directories
          [
            "torrents"
            "torrents/.incomplete"
            "torrents/.watch"
            "torrents/manual"
            "torrents/lidarr"
            "torrents/radarr"
            "torrents/sonarr"
            "torrents/shelfmark"
          ]
          {
            owner = "transmission";
            mode = "0755";
          }
      //
        directories
          [
            "usenet"
            "usenet/.incomplete"
            "usenet/.watch"
            "usenet/watch"
          ]
          {
            owner = "sabnzbd";
            mode = "0755";
          }
      //
        directories
          [
            "usenet/manual"
            "usenet/lidarr"
            "usenet/radarr"
            "usenet/sonarr"
            "usenet/shelfmark"
          ]
          {
            owner = "sabnzbd";
            mode = "0775";
          };
  };
}
