{
  config,
  lib,
  ...
}:
let
  mediaDir = config.nixarr.mediaDir;
  stateDir = config.nixarr.stateDir;
  globals = config.util-nixarr.globals;
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
        port = config.nixarr.audiobookshelf.port;
        stateDir = "${stateDir}/audiobookshelf";
        inherit (globals.audiobookshelf) user group;
      };
      bazarr = {
        port = config.nixarr.bazarr.port;
        stateDir = "${stateDir}/bazarr";
        inherit (globals.bazarr) user group;
      };
      lidarr = {
        port = config.nixarr.lidarr.port;
        stateDir = "${stateDir}/lidarr";
        inherit (globals.lidarr) user group;
      };
      prowlarr = {
        port = config.nixarr.prowlarr.port;
        stateDir = "${stateDir}/prowlarr";
        inherit (globals.prowlarr) user group;
      };
      radarr = {
        port = config.nixarr.radarr.port;
        stateDir = "${stateDir}/radarr";
        inherit (globals.radarr) user group;
      };
      sabnzbd = {
        port = config.nixarr.sabnzbd.guiPort;
        stateDir = "${stateDir}/sabnzbd";
        inherit (globals.sabnzbd) user group;
      };
      seerr = {
        port = config.services.seerr.port;
        stateDir = "${stateDir}/seerr";
        inherit (globals.seerr) user group;
      };
      shelfmark = {
        port = config.nixarr.shelfmark.port;
        stateDir = "${stateDir}/shelfmark";
        inherit (globals.shelfmark) user group;
      };
      sonarr = {
        port = config.nixarr.sonarr.port;
        stateDir = "${stateDir}/sonarr";
        inherit (globals.sonarr) user group;
      };
      transmission = {
        port = config.nixarr.transmission.uiPort;
        peerPort = config.nixarr.transmission.peerPort;
        stateDir = "${stateDir}/transmission";
        inherit (globals.transmission) user group;
      };
    };
  };
}
