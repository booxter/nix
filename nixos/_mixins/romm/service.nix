{
  config,
  lib,
  rommModel,
  ...
}:
let
  model = rommModel;
in
{
  config = lib.mkIf (model.cfg != null && model.ready) {
    services.romm = {
      enable = true;
      user = model.user;
      group = model.storageGroup;
      dataDir = model.basePath;
      port = model.port;
      nginx.enable = false;
      database = {
        createLocally = false;
        host = "localhost";
        port = 3306;
      };
      redis = {
        createLocally = false;
        port = model.cachePort;
      };
      environmentFile = config.sops.templates."romm.env".path;
      extraEnvironment = model.commonEnvironment;
    };

    # The storage claim owns these directories and their shared group modes.
    systemd.tmpfiles.settings."10-romm" = lib.mkForce { };

    # Back up the database before the native service runs migrations.
    systemd.services.romm = {
      requires = model.units.setupBefore;
      after = model.units.setupBefore ++ model.units.tmpfiles;
      serviceConfig.TimeoutStartSec = "10min";
    };
  };
}
