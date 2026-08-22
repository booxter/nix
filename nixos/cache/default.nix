{
  config,
  ...
}:
let
  nfsPath = config.host.storage.claims.nixCache.mountPoint;
in
{
  system.stateVersion = "25.11";

  host.attic.server.storagePath = nfsPath;

  host.proxmox.guest = {
    cluster = "lab";
    cores = 16;
    memoryGiB = 16;
    diskGiB = 50; # actual cache is on NFS
  };

  host.storage.claims.nixCache = {
    provider = "beast";
    mountPoint = "/cache";
  };

  host.ups.client.server = "prx1-lab";
}
