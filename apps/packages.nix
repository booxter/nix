pkgs:
let
  atomicFileWrites = pkgs.python3Packages.callPackage ../pkgs/atomic-file-writes { };
  hostInventory = import ../inv { inherit (pkgs) lib; };
  sopsTools = import ./sops/package.nix { inherit hostInventory pkgs; };
  certificateTools = pkgs.callPackage ./pki-certificates {
    inherit atomicFileWrites hostInventory sopsTools;
  };
  issueProxmoxExporterToken = pkgs.callPackage ./issue-proxmox-exporter-token {
    inherit hostInventory sopsTools;
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
