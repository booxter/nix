pkgs:
let
  ebookConverterCli = pkgs.callPackage ./ebook-converter-cli { };
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

  ebook-converter-cli = ebookConverterCli;

  transmission-common = transmissionCommon;

  aurral = pkgs.callPackage ./aurral { };

  houndarr = pkgs.callPackage ./houndarr { };

  houndarr-tools = pkgs.callPackage ./houndarr-tools { };

  letterboxd-list-radarr = pkgs.callPackage ./letterboxd-list-radarr { };

  seerr-tools = seerrTools.package;

  audiobookshelf-tools = pkgs.callPackage ./audiobookshelf-tools { };

  ebook-converter = pkgs.callPackage ./ebook-converter {
    atomicFileWrites = pkgs.atomic-file-writes;
    inherit ebookConverterCli;
  };

  lidarr-cue-splitter = pkgs.callPackage ./lidarr-cue-splitter {
    atomicFileWrites = pkgs.atomic-file-writes;
  };

  network-tools = pkgs.callPackage ./network-tools { };

  pinepods-tools = pkgs.callPackage ./pinepods-tools { };

  romm-tools = pkgs.callPackage ./romm-tools { };

  transmission-torrent-cleaner = pkgs.callPackage ./transmission-torrent-cleaner {
    inherit transmissionCommon;
  };

  transmission-prioritizer = transmissionTrackerPrioritizer.prioritizer;
  transmission-collector = transmissionTrackerPrioritizer.collector;
}
