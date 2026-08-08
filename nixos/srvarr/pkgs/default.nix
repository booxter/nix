pkgs:
let
  ebookConverterCli = pkgs.callPackage ./ebook-converter-cli { };
  transmissionCommon = pkgs.callPackage ./transmission-common { };
  transmissionTrackerPrioritizer = pkgs.callPackage ./transmission-tracker-prioritizer {
    inherit transmissionCommon;
  };
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

  letterboxd-list-radarr = pkgs.callPackage ./letterboxd-list-radarr { };

  ebook-converter = pkgs.callPackage ./ebook-converter {
    atomicFileWrites = pkgs.atomic-file-writes;
    inherit ebookConverterCli;
  };

  lidarr-cue-splitter = pkgs.callPackage ./lidarr-cue-splitter {
    atomicFileWrites = pkgs.atomic-file-writes;
  };

  transmission-torrent-cleaner = pkgs.callPackage ./transmission-torrent-cleaner {
    inherit transmissionCommon;
  };

  transmission-prioritizer = transmissionTrackerPrioritizer.prioritizer;
  transmission-collector = transmissionTrackerPrioritizer.collector;
}
