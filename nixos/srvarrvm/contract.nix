{
  lib,
  ...
}:
let
  mediaDir = "/data/media";
  stateDir = "/data/.state/nixarr";
in
{
  options.host.srvarr = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    readOnly = true;
    description = "Canonical srvarr media stack paths, ports, and identities.";
  };

  config.host.srvarr = {
    inherit mediaDir stateDir;
    services = {
      aurral = {
        port = 3001;
        stateDir = "${stateDir}/aurral";
        user = "aurral";
        group = "aurral";
      };
      audiobookshelf = {
        port = 9292;
        stateDir = "${stateDir}/audiobookshelf";
        user = "audiobookshelf";
        group = "media";
      };
      bazarr = {
        port = 6767;
        stateDir = "${stateDir}/bazarr";
        user = "bazarr";
        group = "media";
      };
      lidarr = {
        port = 8686;
        stateDir = "${stateDir}/lidarr";
        user = "lidarr";
        group = "media";
      };
      prowlarr = {
        port = 9696;
        stateDir = "${stateDir}/prowlarr";
        user = "prowlarr";
        group = "prowlarr";
      };
      radarr = {
        port = 7878;
        stateDir = "${stateDir}/radarr";
        user = "radarr";
        group = "media";
      };
      sabnzbd = {
        port = 6336;
        stateDir = "${stateDir}/sabnzbd";
        user = "sabnzbd";
        group = "media";
      };
      seerr = {
        port = 5055;
        stateDir = "${stateDir}/seerr";
        user = "seerr";
        group = "seerr";
      };
      shelfmark = {
        port = 8084;
        stateDir = "${stateDir}/shelfmark";
        user = "shelfmark";
        group = "media";
      };
      sonarr = {
        port = 8989;
        stateDir = "${stateDir}/sonarr";
        user = "sonarr";
        group = "media";
      };
      transmission = {
        port = 9091;
        peerPort = 45486;
        stateDir = "${stateDir}/transmission";
        user = "transmission";
        group = "media";
      };
    };
  };
}
