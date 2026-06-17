# You can build them using 'nix build .#example'
pkgs:
let
  issueInternalServiceCert = pkgs.callPackage ./issue-internal-service-cert { };
  issueObservabilityCert = pkgs.callPackage ./issue-observability-cert { };
  issueProxmoxExporterToken = pkgs.callPackage ./issue-proxmox-exporter-token { };
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

  issue-proxmox-exporter-token = issueProxmoxExporterToken;

  pki-rotation = pkgs.callPackage ./pki-rotation {
    inherit issueInternalServiceCert issueObservabilityCert;
  };

  ssh-ticket = pkgs.callPackage ./ssh-ticket { };

  unifi-sync = pkgs.callPackage ./unifi-sync { };

  wg-home-exporter = pkgs.callPackage ./wg-home-exporter { };

  wg-home-dns-sync = pkgs.callPackage ./wg-home-dns-sync { };

  fleet-cache-warmer = pkgs.callPackage ./fleet-cache-warmer { };

  jellyfin-exporter = pkgs.callPackage ./jellyfin-exporter { };

  transmission-torrent-cleaner = pkgs.callPackage ./transmission-torrent-cleaner { };

  transmission-prioritizer = transmissionTrackerTools.prioritizer;
  transmission-collector = transmissionTrackerTools.collector;
}
