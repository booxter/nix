{ mediaLibraries }:
let
  mediaDirectory =
    {
      path,
      owner ? "root",
      mode ? "2775",
    }:
    {
      inherit path owner mode;
      group = "media";
      enforce = true;
    };
  mediaDirectories =
    map (path: mediaDirectory { inherit path; }) [
      "library"
      "library/books"
      "library/audiobooks"
      "library/flows"
      "podcasts"
    ]
    ++ [
      (mediaDirectory {
        path = "podcasts/pinepods";
        owner = "pinepods";
      })
    ]
    ++
      map
        (
          path:
          mediaDirectory {
            inherit path;
            owner = "romm";
          }
        )
        [
          "romm"
          "romm/assets"
          "romm/config"
          "romm/resources"
          "romm/sync"
          "romm/library"
          "romm/library/roms"
          "romm/library/roms/pc"
          "romm/library/bios"
        ]
    ++
      map
        (
          path:
          mediaDirectory {
            inherit path;
            owner = "transmission";
            mode = "0755";
          }
        )
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
    ++
      map
        (
          path:
          mediaDirectory {
            inherit path;
            owner = "slskd";
          }
        )
        [
          "slskd"
          "slskd/incomplete"
          "slskd/complete"
        ]
    ++
      map
        (
          path:
          mediaDirectory {
            inherit path;
            owner = "sabnzbd";
            mode = "0755";
          }
        )
        [
          "usenet"
          "usenet/.incomplete"
          "usenet/.watch"
          "usenet/watch"
        ]
    ++
      map
        (
          path:
          mediaDirectory {
            inherit path;
            owner = "sabnzbd";
            mode = "0775";
          }
        )
        [
          "usenet/manual"
          "usenet/lidarr"
          "usenet/radarr"
          "usenet/sonarr"
          "usenet/shelfmark"
        ]
    ++ map (library: mediaDirectory { path = "library/${library.path}"; }) mediaLibraries;
in
{
  resources = {
    media = {
      provider = "beast";
      path = "/volume2/Media";
      sharedGroup = "media";
      identities.groups = [ "media" ];
      directories = mediaDirectories;
    };

    nixCache = {
      provider = "beast";
      path = "/volume2/nix-cache";
      # Attic manages the existing export root and its ownership.
      directories = [ ];
    };

    paperless = {
      provider = "beast";
      path = "/volume2/paperless";
      identities = {
        groups = [ "paperless" ];
        users = [ "paperless" ];
      };
      directories =
        map
          (path: {
            inherit path;
            mode = "0750";
            owner = "paperless";
            group = "paperless";
          })
          [
            "."
            "consume"
            "export"
            "media"
          ];
    };
  };
}
