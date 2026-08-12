pkgs:
let
  atomicFileWrites = pkgs.python3Packages.callPackage ../pkgs/atomic-file-writes { };
  facts = import ../facts { inherit (pkgs) lib; };
  sopsTools = import ./sops/package.nix { inherit facts pkgs; };
  certificateTools = pkgs.callPackage ./pki-certificates {
    inherit atomicFileWrites sopsTools;
  };
  issueProxmoxExporterToken = pkgs.callPackage ./issue-proxmox-exporter-token {
    inherit facts sopsTools;
  };
  getFfCookie = pkgs.callPackage ./get-ff-cookie { };
  seerrTools = pkgs.callPackage ../nixos/srvarr/pkgs/seerr-tools { };
in
{
  get-ff-cookie = getFfCookie;

  issue-internal-service-cert = certificateTools;

  issue-observability-cert = certificateTools;

  issue-proxmox-exporter-token = issueProxmoxExporterToken;

  seerr-request-storage = seerrTools.requestStorage;

  seerr-update-user-tags = seerrTools.updateUserTags;
}
