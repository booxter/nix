{
  lib,
  ...
}:
let
  stateDir = "/data/.state/nixarr";
in
{
  options.host.srvarr = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    readOnly = true;
    description = "Canonical srvarr media stack paths, ports, and identities.";
  };

  config.host.srvarr = {
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
        stateDir = "${stateDir}/bazarr";
        user = "bazarr";
        group = "media";
      };
      lidarr = {
        stateDir = "${stateDir}/lidarr";
        user = "lidarr";
        group = "media";
      };
      prowlarr = {
        stateDir = "${stateDir}/prowlarr";
        user = "prowlarr";
        group = "prowlarr";
      };
      radarr = {
        stateDir = "${stateDir}/radarr";
        user = "radarr";
        group = "media";
      };
      sabnzbd = {
        port = 6336;
        user = "sabnzbd";
        group = "media";
      };
      seerr = {
        stateDir = "${stateDir}/seerr";
        user = "seerr";
        group = "seerr";
      };
      shelfmark = {
        stateDir = "${stateDir}/shelfmark";
        user = "shelfmark";
        group = "media";
      };
      sonarr = {
        stateDir = "${stateDir}/sonarr";
        user = "sonarr";
        group = "media";
      };
      transmission = {
        peerPort = 45486;
        stateDir = "${stateDir}/transmission";
        user = "transmission";
        group = "media";
      };
    };
  };
}
