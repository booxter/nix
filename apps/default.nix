pkgs:
let
  hostInventory = import ../lib/inventory.nix { inherit (pkgs) lib; };
  sopsTools = import ./sops/package.nix { inherit hostInventory pkgs; };
  issueInternalServiceCert = pkgs.callPackage ./issue-internal-service-cert {
    inherit sopsTools;
  };
  issueObservabilityCert = pkgs.callPackage ./issue-observability-cert {
    inherit sopsTools;
  };
  issueProxmoxExporterToken = pkgs.callPackage ./issue-proxmox-exporter-token { };
  seerrRequestStorage = pkgs.callPackage ./seerr-request-storage { };
  seerrUpdateUserTags = pkgs.callPackage ./seerr-update-user-tags { };
in
{
  issue-internal-service-cert = issueInternalServiceCert;

  issue-observability-cert = issueObservabilityCert;

  issue-proxmox-exporter-token = issueProxmoxExporterToken;

  seerr-request-storage = seerrRequestStorage;

  seerr-update-user-tags = seerrUpdateUserTags;
}
