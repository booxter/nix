pkgs:
let
  issueInternalServiceCert = pkgs.callPackage ./issue-internal-service-cert { };
  issueObservabilityCert = pkgs.callPackage ./issue-observability-cert { };
  issueProxmoxExporterToken = pkgs.callPackage ./issue-proxmox-exporter-token { };
in
{
  issue-internal-service-cert = issueInternalServiceCert;

  issue-observability-cert = issueObservabilityCert;

  issue-proxmox-exporter-token = issueProxmoxExporterToken;
}
