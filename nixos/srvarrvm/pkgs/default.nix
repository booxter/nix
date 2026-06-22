pkgs:
let
  transmissionTrackerTools = pkgs.callPackage ./transmission-tracker-prioritizer { };
in
{
  adaptive-upload-controller = pkgs.callPackage ./adaptive-upload-controller { };

  transmission-torrent-cleaner = pkgs.callPackage ./transmission-torrent-cleaner { };

  transmission-prioritizer = transmissionTrackerTools.prioritizer;
  transmission-collector = transmissionTrackerTools.collector;
}
