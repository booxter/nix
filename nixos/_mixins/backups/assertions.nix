{
  backupTopology,
  config,
  lib,
  ...
}:
let
  cfg = config.host.backups;
  inherit (cfg) jobs;
  server = if cfg.server == null then null else cfg.server // backupTopology.server;
  sources = lib.filterAttrs (_: source: source.enable) cfg.sources;
  preparationPaths =
    job: lib.concatMap (preparation: preparation.paths) (builtins.attrValues job.preparations);
  databaseCapture = source: source.database != null;
in
{
  assertions =
    lib.concatLists (
      lib.mapAttrsToList (name: job: [
        {
          assertion = job.paths != [ ] || preparationPaths job != [ ];
          message = "host.backups.jobs.${name} must include at least one path";
        }
        {
          assertion =
            job.repository.type != "sftp"
            || (
              job.repository.sftp.host != null
              && job.repository.sftp.user != null
              && job.repository.sftp.identityFile != null
            );
          message = "host.backups.jobs.${name} requires complete SFTP settings";
        }
      ]) jobs
    )
    ++ lib.concatLists (
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
    ++ lib.optionals (server != null) (
      [
        {
          assertion = server.repositories != { };
          message = "host.backups.server.repositories must not be empty";
        }
        {
          assertion =
            server.offsite == null || server.offsite.backend != "s3" || server.offsite.endpoint != null;
          message = "host.backups.server.offsite.endpoint is required for S3 replication";
        }
        {
          assertion = server.localClient == null || builtins.hasAttr server.localClient server.repositories;
          message = "host.backups.server.localClient must reference a configured client";
        }
        {
          assertion =
            server.localClient == null
            || !builtins.hasAttr server.localClient server.repositories
            || server.repositories.${server.localClient}.cloud.enable;
          message = "host.backups.server.localClient must have cloud offload enabled";
        }
      ]
      ++ lib.mapAttrsToList (name: client: {
        assertion =
          !client.cloud.enable
          || (
            client.cloud.repository != ""
            && client.cloud.sourcePasswordFile != ""
            && client.cloud.passwordFile != ""
            && (client.cloud.backend == "local" || client.cloud.prefix != "")
          );
        message = "host.backups.server.repositories.${name}.cloud requires complete repository credentials";
      }) server.repositories
    )
    ++ lib.optional (server != null && server.offsite != null && server.offsite.qos) {
      assertion = config.host.network.primaryInterface != null;
      message = "backup cloud-offload policy requires host.network.primaryInterface";
    };
}
