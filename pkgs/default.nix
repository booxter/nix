# You can build them using 'nix build .#example'
pkgs:
let
  appPackages = import ../apps pkgs;
in
{
  join-media-parts = pkgs.callPackage ./join-media-parts { };

  pki-rotation = pkgs.callPackage ./pki-rotation {
    issueInternalServiceCert = appPackages.issue-internal-service-cert;
    issueObservabilityCert = appPackages.issue-observability-cert;
  };
}
