{
  backupTopology,
  config,
  lib,
  ...
}:
let
  cfg = config.host.backups;
  server = if cfg.server == null then null else cfg.server // backupTopology.server;
  sources = lib.filterAttrs (_: source: source.enable) cfg.sources;
  databaseCapture = source: source.database != null;
in
{
  assertions =
    lib.concatLists (
      lib.mapAttrsToList (name: source: [
        {
          assertion = cfg.destination != null;
          message = "host.backups.sources.${name} requires host.backups.destination";
        }
        {
          assertion =
            source.paths != [ ]
            || (source.preparation != null && source.preparation.paths != [ ])
            || databaseCapture source;
          message = "host.backups.sources.${name} must contribute a path or database capture";
        }
        {
          assertion =
            !databaseCapture source || source.database.type != "sqlite" || source.database.path != null;
          message = "host.backups.sources.${name} database capture is incomplete";
        }
      ]) sources
    )
    ++ lib.optionals (server != null) ([
      {
        assertion = server.repositories != { };
        message = "host.backups.server.repositories must not be empty";
      }
      {
        assertion =
          server.offsite == null || server.offsite.backend != "s3" || server.offsite.endpoint != null;
        message = "host.backups.server.offsite.endpoint is required for S3 replication";
      }
    ])
    ++ lib.optional (server != null && server.offsite != null && server.offsite.qos) {
      assertion = config.host.network.primaryInterface != null;
      message = "backup cloud-offload policy requires host.network.primaryInterface";
    };
}
