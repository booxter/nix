pkgs:
let
  common = pkgs.callPackage ./common { };
  trackerPrioritizer = pkgs.callPackage ./tracker-prioritizer {
    transmissionCommon = common;
  };
in
{
  inherit common;
  collector = trackerPrioritizer.collector;
  prioritizer = trackerPrioritizer.prioritizer;
  torrentCleaner = pkgs.callPackage ./torrent-cleaner {
    transmissionCommon = common;
  };
}
