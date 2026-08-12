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
    endpoint = config.host.web.services.atticd.internal.url;
    storagePath = nfsPath;
    trustedPublicKey = facts.public-keys.nix-cache.home;
  };

  host.storage.claims.nixCache = {
    provider = "beast";
    mountPoint = "/cache";
  };

  host.ups.client.server = "prx1-lab";

  host.web.services.atticd = {
    enable = true;
    upstream = "http://127.0.0.1:8080";
    internal = {
      serverName = "nix-cache.${config.host.network.lanDomain}";
      localAliases = [ "nix-cache" ];
      locationExtraConfig = ''
        client_max_body_size 0;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
      '';
    };
  };
}
