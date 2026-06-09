{ hostInventory, lib, ... }:
let
  nfsPort = hostInventory.site.ports.nfs;
  srvarrNfsAddress = hostInventory.toNixosHostIpv4Address "srvarr";
  cacheNfsAddress = hostInventory.toNixosHostIpv4Address "cache";

  # Pin export IDs so clients see stable export identities across server restarts.
  mkNfsExport =
    {
      path,
      client,
      fsid,
    }:
    "${path} ${client}(rw,async,no_subtree_check,fsid=${toString fsid})";
in
{
  # NFS exports matching existing clients.
  services.nfs.server = {
    enable = true;
    exports = ''
      ${mkNfsExport {
        path = "/volume2/Media";
        client = srvarrNfsAddress;
        fsid = 10; # media export
      }}
      ${mkNfsExport {
        path = "/volume2/nix-cache";
        client = cacheNfsAddress;
        fsid = 11; # binary cache export
      }}
    '';
  };

  systemd.services.nfs-server = {
    # If /volume2 misses the initial boot transaction but mounts later, pull
    # NFS back up with it instead of leaving clients stuck until manual repair.
    wantedBy = [ "volume2.mount" ];
    unitConfig.RequiresMountsFor = [
      "/volume2"
      "/volume2/Media"
      "/volume2/nix-cache"
    ];
  };

  services.nfs.settings.nfsd = {
    vers3 = "n";
    vers4 = "y";
  };

  services.rpcbind.enable = lib.mkForce false;

  networking.firewall.allowedTCPPorts = [ nfsPort ];
}
