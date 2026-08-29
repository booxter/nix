{
  config,
  lib,
  ...
}:
let
  nfsPath = config.host.storage.claims.nixCache.mountPoint;
in
{
  system.stateVersion = "25.11";

  host.attic.server.storagePath = nfsPath;

  services.atticd.settings.garbage-collection.interval = lib.mkForce "0 seconds";

  host.proxmox.guest = {
    cores = 16;
    memoryGiB = 16;
    diskGiB = 50; # actual cache is on NFS
  };

  host.storage.claims.nixCache = {
    provider = "beast";
    mountPoint = "/cache";
  };

}
