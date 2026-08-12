pkgs:
let
  transmissionCommon = pkgs.callPackage ./transmission-common { };
  transmissionTrackerPrioritizer = pkgs.callPackage ./transmission-tracker-prioritizer {
    inherit transmissionCommon;
  };
  seerrTools = pkgs.callPackage ./seerr-tools { };
in
{
  bazarr-auth-config = pkgs.callPackage ./bazarr-auth-config {
    atomicFileWrites = pkgs.atomic-file-writes;
  };

  dynamic-ip-updater = pkgs.callPackage ./dynamic-ip-updater {
    atomicFileWrites = pkgs.atomic-file-writes;
  };

  # Removed once the srvarr deployment consumes host.ebookConverter directly.
  ebook-converter = import ../../_mixins/ebook-converter/package { inherit pkgs; };

  transmission-common = transmissionCommon;

  houndarr = pkgs.callPackage ./houndarr { };

  houndarr-tools = pkgs.callPackage ./houndarr-tools { };

  letterboxd-list-radarr = pkgs.callPackage ./letterboxd-list-radarr { };

  seerr-tools = seerrTools.package;

  audiobookshelf-tools = pkgs.callPackage ./audiobookshelf-tools { };

  lidarr-cue-splitter = pkgs.callPackage ./lidarr-cue-splitter {
    atomicFileWrites = pkgs.atomic-file-writes;
  };

  pinepods-tools = pkgs.callPackage ./pinepods-tools { };

  romm-tools = pkgs.callPackage ./romm-tools { };

  transmission-torrent-cleaner = pkgs.callPackage ./transmission-torrent-cleaner {
    inherit transmissionCommon;
  };

  transmission-prioritizer = transmissionTrackerPrioritizer.prioritizer;
  transmission-collector = transmissionTrackerPrioritizer.collector;
}
