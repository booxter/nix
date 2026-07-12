pkgs:
let
  transmissionCommon = pkgs.callPackage ./transmission-common { };
  transmissionTrackerPrioritizer = pkgs.callPackage ./transmission-tracker-prioritizer {
    inherit transmissionCommon;
  };
in
{
  transmission-common = transmissionCommon;

  aurral = pkgs.callPackage ./aurral { };

  letterboxd-list-radarr = pkgs.callPackage ./letterboxd-list-radarr { };

  adaptive-upload-controller = pkgs.callPackage ./adaptive-upload-controller {
    inherit transmissionCommon;
  };

  audiobookshelf-oidc-bootstrap = pkgs.callPackage ./audiobookshelf-oidc-bootstrap { };

  lidarr-cue-splitter = pkgs.callPackage ./lidarr-cue-splitter { };

  transmission-torrent-cleaner = pkgs.callPackage ./transmission-torrent-cleaner {
    inherit transmissionCommon;
  };

  transmission-prioritizer = transmissionTrackerPrioritizer.prioritizer;
  transmission-collector = transmissionTrackerPrioritizer.collector;
}
