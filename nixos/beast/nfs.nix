{ hostInventory, lib, ... }:
let
  nfsSubnet = hostInventory.site.lan.cidr;
  nfsPort = hostInventory.site.ports.nfs;

  # Pin export IDs so clients see stable export identities across server restarts.
  mkNfsExport =
    { path, fsid }: "${path} ${nfsSubnet}(rw,async,no_subtree_check,fsid=${toString fsid})";
in
{
  # NFS exports matching existing clients.
  services.nfs.server = {
    enable = true;
    exports = ''
      ${mkNfsExport {
        path = "/volume2/Media";
        fsid = 10; # media export
      }}
      ${mkNfsExport {
        path = "/volume2/nix-cache";
        fsid = 11; # binary cache export
      }}
    '';
  };

  systemd.services.nfs-server.unitConfig.RequiresMountsFor = [
    "/volume2"
    "/volume2/Media"
    "/volume2/nix-cache"
  ];

  services.nfs.settings.nfsd = {
    vers3 = "n";
    vers4 = "y";
  };

  services.rpcbind.enable = lib.mkForce false;

  networking.firewall.allowedTCPPorts = [ nfsPort ];
  networking.firewall.allowedUDPPorts = [ nfsPort ];
}
