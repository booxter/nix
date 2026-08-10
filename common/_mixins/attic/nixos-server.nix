{ config, lib, ... }:
let
  cfg = config.host.attic.server;
in
{
  config = lib.mkIf cfg.enable {
    services.atticd = {
      enable = true;
      environmentFile = cfg.environmentFile;
      settings = {
        listen = "127.0.0.1:8080";
        jwt = { };

        # Changing these values prevents existing chunks from being reused for
        # newly uploaded NARs until the cache gradually deduplicates again.
        chunking = {
          nar-size-threshold = 64 * 1024;
          min-size = 16 * 1024;
          avg-size = 64 * 1024;
          max-size = 256 * 1024;
        };

        storage = {
          type = "local";
          path = cfg.storagePath;
        };
      };
    };

    systemd.services.atticd.unitConfig.RequiresMountsFor = cfg.storagePath;
  };
}
