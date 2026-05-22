{ lib, ... }:
let
  mediaLibraries = import ./media-libraries.nix;
  mediaPaths = import ./media-paths.nix;
  mediaRoot = "/volume2/Media";
  mediaTorrentRoot = "${mediaRoot}/torrents";
  mediaUsenetRoot = "${mediaRoot}/usenet";

  mkTmpfilesDir = path: mode: user: group: [
    "d ${path} ${mode} ${user} ${group} - -"
    "z ${path} ${mode} ${user} ${group} - -"
  ];

  mediaDirSpecs = [
    {
      path = mediaPaths.sourceLibraryRoot;
      mode = "2775";
      user = "root";
      group = "media";
    }
    {
      path = "${mediaPaths.sourceLibraryRoot}/books";
      mode = "2775";
      user = "root";
      group = "media";
    }
    {
      path = "${mediaPaths.sourceLibraryRoot}/audiobooks";
      mode = "2775";
      user = "root";
      group = "media";
    }
    {
      path = "${mediaPaths.sourceLibraryRoot}/podcasts";
      mode = "2775";
      user = "root";
      group = "media";
    }
    {
      path = "${mediaPaths.sourceLibraryRoot}/flows";
      mode = "2775";
      user = "root";
      group = "media";
    }
    {
      path = mediaTorrentRoot;
      mode = "0755";
      user = "70";
      group = "media";
    }
    {
      path = "${mediaTorrentRoot}/.incomplete";
      mode = "0755";
      user = "70";
      group = "media";
    }
    {
      path = "${mediaTorrentRoot}/.watch";
      mode = "0755";
      user = "70";
      group = "media";
    }
    {
      path = "${mediaTorrentRoot}/manual";
      mode = "0755";
      user = "70";
      group = "media";
    }
    {
      path = "${mediaTorrentRoot}/lidarr";
      mode = "0755";
      user = "70";
      group = "media";
    }
    {
      path = "${mediaTorrentRoot}/radarr";
      mode = "0755";
      user = "70";
      group = "media";
    }
    {
      path = "${mediaTorrentRoot}/sonarr";
      mode = "0755";
      user = "70";
      group = "media";
    }
    {
      path = "${mediaTorrentRoot}/shelfmark";
      mode = "0755";
      user = "70";
      group = "media";
    }
    {
      path = mediaUsenetRoot;
      mode = "0755";
      user = "38";
      group = "media";
    }
    {
      path = "${mediaUsenetRoot}/.incomplete";
      mode = "0755";
      user = "38";
      group = "media";
    }
    {
      path = "${mediaUsenetRoot}/.watch";
      mode = "0755";
      user = "38";
      group = "media";
    }
    {
      path = "${mediaUsenetRoot}/watch";
      mode = "0755";
      user = "38";
      group = "media";
    }
    {
      path = "${mediaUsenetRoot}/manual";
      mode = "0775";
      user = "38";
      group = "media";
    }
    {
      path = "${mediaUsenetRoot}/lidarr";
      mode = "0775";
      user = "38";
      group = "media";
    }
    {
      path = "${mediaUsenetRoot}/radarr";
      mode = "0775";
      user = "38";
      group = "media";
    }
    {
      path = "${mediaUsenetRoot}/sonarr";
      mode = "0775";
      user = "38";
      group = "media";
    }
    {
      path = "${mediaUsenetRoot}/shelfmark";
      mode = "0775";
      user = "38";
      group = "media";
    }
  ]
  ++ map (library: {
    path = "${mediaPaths.sourceLibraryRoot}/${library.path}";
    mode = "2775";
    user = "root";
    group = "media";
  }) mediaLibraries;
in
{
  systemd.tmpfiles.rules = lib.concatMap (
    spec: mkTmpfilesDir spec.path spec.mode spec.user spec.group
  ) mediaDirSpecs;
}
