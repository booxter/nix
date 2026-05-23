# You can build them using 'nix build .#example'
pkgs:
let
  transmissionTrackerTools = pkgs.callPackage ./transmission-tracker-prioritizer { };
in
{
  # private
  my-page = pkgs.callPackage ./page { };

  # to upstream?
  jinjanator = pkgs.callPackage ./jinjanator { };

  ismc = pkgs.callPackage ./ismc { };

  join-media-parts = pkgs.callPackage ./join-media-parts { };

  aurral = pkgs.callPackage ./aurral { };

  adaptive-upload-controller = pkgs.callPackage ./adaptive-upload-controller { };

  unifi-fixed-reservation = pkgs.callPackage ./unifi-fixed-reservation { };

  fleet-cache-warmer = pkgs.callPackage ./fleet-cache-warmer { };

  jellyfin-exporter = pkgs.callPackage ./jellyfin-exporter { };

  transmission-torrent-cleaner = pkgs.callPackage ./transmission-torrent-cleaner { };

  transmission-prioritizer = transmissionTrackerTools.prioritizer;
  transmission-collector = transmissionTrackerTools.collector;
}
