{
  config,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix { inherit config lib outputs; };
  inherit (model) cfg gptStateDir storagePath;
in
{
  config = lib.mkIf cfg.enable {
    host.storage.claims.paperless = {
      provider = cfg.storage.provider;
      resource = cfg.storage.resource;
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
        capture = {
          type = "postgresql";
          database.destinationDir = "/var/lib/paperless-backup/latest";
          database.requiresMountsFor = [ config.services.paperless.dataDir ];
        };
      };
    }
    // lib.optionalAttrs cfg.gpt.enable {
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
