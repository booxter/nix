# You can build them using 'nix build .#example'
pkgs:
let
  appPackages = import ../apps pkgs;
in
{
  # private
  my-page = pkgs.callPackage ./page { };

  ismc = pkgs.callPackage ./ismc { };

  join-media-parts = pkgs.callPackage ./join-media-parts { };

  aurral = pkgs.callPackage ./aurral { };

  pki-rotation = pkgs.callPackage ./pki-rotation {
    issueInternalServiceCert = appPackages.issue-internal-service-cert;
    issueObservabilityCert = appPackages.issue-observability-cert;
  };

  ssh-ticket = pkgs.callPackage ./ssh-ticket { };

  unifi-sync = pkgs.callPackage ./unifi-sync { };

  wg-home-dns-sync = pkgs.callPackage ./wg-home-dns-sync { };

  jellyfin-exporter = pkgs.callPackage ./jellyfin-exporter { };
}
