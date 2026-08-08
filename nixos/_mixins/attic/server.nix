{
  config,
  hostInventory,
  lib,
  ...
}:
let
  realmAttic = hostInventory.realms.${config.host.realm}.services.attic or null;
  isServer = realmAttic != null && realmAttic.serverHost == config.networking.hostName;
  port = 8080;
  storagePath = "/cache";
  serviceName = if realmAttic == null then "" else realmAttic.localDnsName;
  storageExport = if realmAttic == null then "" else realmAttic.storageExport;
in
{
  config = lib.mkIf isServer {
    host.nfs.mounts.${storageExport} = storagePath;

    services.atticd = {
      enable = true;

      # TODO: render this from a SOPS-managed Attic server JWT key.
      environmentFile = "/etc/atticd.env";

      settings = {
        listen = "127.0.0.1:${toString port}";
        jwt = { };

        # Pin chunk boundaries so upstream defaults cannot change existing
        # deduplication behavior.
        chunking = {
          nar-size-threshold = 64 * 1024;
          min-size = 16 * 1024;
          avg-size = 64 * 1024;
          max-size = 256 * 1024;
        };

        storage = {
          type = "local";
          path = storagePath;
        };
      };
    };

    host.internalHttps.services.atticd = {
      enable = true;
      serverName = "${serviceName}.${hostInventory.site.lan.domain}";
      localAliases = [ serviceName ];
      upstream = "http://127.0.0.1:${toString port}";
      locationExtraConfig = ''
        client_max_body_size 0;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
      '';
    };

    systemd.services.atticd.unitConfig.RequiresMountsFor = storagePath;
  };
}
