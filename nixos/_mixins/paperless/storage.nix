{
  config,
  lib,
  paperlessModel,
  ...
}:
let
  inherit (paperlessModel) cfg gptStateDir storagePath;
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
    }
    // lib.optionalAttrs (cfg.gpt != null) {
      paperless-gpt.paths = [ gptStateDir ];
    };

    systemd.services = {
      paperless-scheduler.unitConfig.RequiresMountsFor = [ storagePath ];
      paperless-consumer.unitConfig.RequiresMountsFor = [ storagePath ];
      paperless-task-queue.unitConfig.RequiresMountsFor = [ storagePath ];
      paperless-web.unitConfig.RequiresMountsFor = [ storagePath ];
    };

    # Paperless' upstream module would create media and consumption
    # directories locally. They live on provider-owned storage instead.
    systemd.tmpfiles.settings."10-paperless" = lib.mkForce {
      "${config.services.paperless.dataDir}".d = {
        user = config.services.paperless.user;
        group = config.users.users.${config.services.paperless.user}.group;
      };
    };
  };
}
