{ config, lib, ... }:
let
  cfg = config.host.attic.server;
  inherit (cfg.chunking)
    avgSize
    maxSize
    minSize
    narSizeThreshold
    ;
  listenAddress = "127.0.0.1:${toString cfg.port}";
in
{
  config = lib.mkIf cfg.enable {
    host.autoUpgrade.claims.attic-server = {
      switch = {
        cadence = "weekly";
        weekday = "Tue";
      };
      reboot = {
        cadence = "weekly";
        weekday = "Tue";
      };
    };

    host.web.services.atticd = {
      upstream = "http://${listenAddress}";
      internal = {
        inherit (cfg) localAliases;
        locationExtraConfig = ''
          client_max_body_size 0;
          proxy_request_buffering off;
          proxy_buffering off;
          proxy_read_timeout 3600s;
          proxy_send_timeout 3600s;
        '';
      };
    };

    services.atticd = {
      enable = true;
      environmentFile = cfg.environmentFile;
      settings = {
        listen = listenAddress;
        jwt = { };

        garbage-collection = {
          interval = "12 hours";
          default-retention-period = "3 months";
        };

        # Changing these values prevents existing chunks from being reused for
        # newly uploaded NARs until the cache gradually deduplicates again.
        chunking = {
          nar-size-threshold = narSizeThreshold;
          min-size = minSize;
          avg-size = avgSize;
          max-size = maxSize;
        };

        storage = {
          type = "local";
          path = cfg.storagePath;
        };
      }
      // lib.optionalAttrs (cfg.databaseUrl != null) {
        database = {
          url = cfg.databaseUrl;
          heartbeat = true;
        };
      };
    };

    systemd.services.atticd.unitConfig.RequiresMountsFor = cfg.storagePath;
  };
}
