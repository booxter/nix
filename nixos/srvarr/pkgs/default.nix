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
  ebook-converter-cli = ebookConverterCli;

  transmission-common = transmissionCommon;

  aurral = pkgs.callPackage ./aurral { };

  houndarr = pkgs.callPackage ./houndarr { };

  letterboxd-list-radarr = pkgs.callPackage ./letterboxd-list-radarr { };

  seerr-tools = seerrTools.package;

  adaptive-upload-controller = pkgs.callPackage ./adaptive-upload-controller {
    inherit transmissionCommon;
  };

  audiobookshelf-oidc-bootstrap = pkgs.callPackage ./audiobookshelf-oidc-bootstrap { };

  ebook-converter = pkgs.callPackage ./ebook-converter {
    inherit ebookConverterCli;
  };

  lidarr-cue-splitter = pkgs.callPackage ./lidarr-cue-splitter { };

  transmission-torrent-cleaner = pkgs.callPackage ./transmission-torrent-cleaner {
    inherit transmissionCommon;
  };

  transmission-prioritizer = transmissionTrackerPrioritizer.prioritizer;
  transmission-collector = transmissionTrackerPrioritizer.collector;
}
