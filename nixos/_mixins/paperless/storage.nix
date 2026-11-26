{
  config,
  lib,
  paperlessModel,
  ...
}:
let
  inherit (paperlessModel) cfg storagePath;
in
{
  config = lib.mkIf (cfg != null) {
    host.storage.claims.paperless = {
      provider = cfg.storageProvider;
      resource = "paperless";
      mountPoint = storagePath;
      directories = {
        "." = { };
        consume = { };
        export = { };
        media = { };
      };
    };

    host.backups.sources = {
      paperless = {
        paths = [
          config.services.paperless.dataDir
          storagePath
        ];
        database = {
          type = "postgresql";
          stagingDir = "/var/lib/paperless-backup/latest";
          requiresMountsFor = [ config.services.paperless.dataDir ];
        };
      };
    };

    systemd.services = {
      paperless-scheduler.unitConfig.RequiresMountsFor = [ storagePath ];
      paperless-consumer.unitConfig.RequiresMountsFor = [ storagePath ];
      paperless-task-queue.unitConfig.RequiresMountsFor = [ storagePath ];
      paperless-web.unitConfig.RequiresMountsFor = [ storagePath ];
    };

    # Paperless' upstream module would create media and consumption
    # directories locally. They live on provider-owned storage instead.
    systemd.tmpfiles.settings."10-paperless" = {
      "${config.services.paperless.mediaDir}" = lib.mkForce { };
      "${config.services.paperless.consumptionDir}" = lib.mkForce { };
    };
  };
}
