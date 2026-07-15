pkgs:
let
  issueInternalServiceCert = pkgs.callPackage ./issue-internal-service-cert { };
  issueObservabilityCert = pkgs.callPackage ./issue-observability-cert { };
  issueProxmoxExporterToken = pkgs.callPackage ./issue-proxmox-exporter-token { };
  seerrUpdateUserTags = pkgs.callPackage ./seerr-update-user-tags { };
in
{
  issue-internal-service-cert = issueInternalServiceCert;

  issue-observability-cert = issueObservabilityCert;

  issue-proxmox-exporter-token = issueProxmoxExporterToken;

  seerr-update-user-tags = seerrUpdateUserTags;
}
