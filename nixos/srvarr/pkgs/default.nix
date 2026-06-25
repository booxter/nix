pkgs:
let
  transmissionTrackerTools = pkgs.callPackage ./transmission-tracker-prioritizer { };
in
{
  aurral = pkgs.callPackage ./aurral { };

  letterboxd-list-radarr = pkgs.callPackage ./letterboxd-list-radarr { };

  adaptive-upload-controller = pkgs.callPackage ./adaptive-upload-controller { };

  audiobookshelf-oidc-bootstrap = pkgs.callPackage ./audiobookshelf-oidc-bootstrap { };

  transmission-torrent-cleaner = pkgs.callPackage ./transmission-torrent-cleaner { };

  transmission-prioritizer = transmissionTrackerTools.prioritizer;
  transmission-collector = transmissionTrackerTools.collector;
}
