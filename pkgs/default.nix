# You can build them using 'nix build .#example'
pkgs:
let
  issueInternalServiceCert = pkgs.callPackage ./issue-internal-service-cert { };
  issueObservabilityCert = pkgs.callPackage ./issue-observability-cert { };
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

  darwin-lan-wan-bpf = pkgs.callPackage ./darwin-lan-wan-bpf { };

  issue-internal-service-cert = issueInternalServiceCert;

  issue-observability-cert = issueObservabilityCert;

  pki-rotation = pkgs.callPackage ./pki-rotation {
    inherit issueInternalServiceCert issueObservabilityCert;
  };

  unifi-sync = pkgs.callPackage ./unifi-sync { };

  fleet-cache-warmer = pkgs.callPackage ./fleet-cache-warmer { };

  jellyfin-exporter = pkgs.callPackage ./jellyfin-exporter { };

  transmission-torrent-cleaner = pkgs.callPackage ./transmission-torrent-cleaner { };

  transmission-prioritizer = transmissionTrackerTools.prioritizer;
  transmission-collector = transmissionTrackerTools.collector;
}
