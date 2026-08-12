{
  config,
  facts,
  ...
}:
let
  nfsPath = config.host.storage.claims.nixCache.mountPoint;
in
{
  system.stateVersion = "25.11";

  host.network = {
    macAddress = "bc:24:11:0d:85:41";
    reservation = {
      enable = true;
      address = "192.168.20.7";
    };
  };

  host.attic.server = {
    enable = true;
    storagePath = nfsPath;
    trustedPublicKey = facts.public-keys.nix-cache.home;
  };

  host.storage.claims.nixCache = {
    provider = "beast";
    mountPoint = "/cache";
  };

  host.ups.client.server = "prx1-lab";
}
