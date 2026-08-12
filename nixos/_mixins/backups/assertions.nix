{ config, lib, ... }:
let
  cfg = config.host.backups;
  inherit (cfg) jobs server;
  sources = lib.filterAttrs (_: source: source.enable) cfg.sources;
  preparationPaths =
    job: lib.concatMap (preparation: preparation.paths) (builtins.attrValues job.preparations);
  databaseCapture =
    source:
    builtins.elem source.capture.type [
      "sqlite"
      "postgresql"
      "mariadb"
    ];
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
          assertion =
            builtins.hasAttr source.destination cfg.destinations
            && cfg.destinations.${source.destination}.enable;
          message = "host.backups.sources.${name} references unknown destination '${source.destination}'";
        }
        {
          assertion =
            source.paths != [ ]
            || (source.capture.type == "unit" && source.capture.unit.outputPaths != [ ])
            || (source.capture.type == "scheduled" && source.capture.scheduled.outputPaths != [ ])
            || databaseCapture source;
          message = "host.backups.sources.${name} must contribute a path or database capture";
        }
        {
          assertion = source.capture.type != "unit" || source.capture.unit.service != null;
          message = "host.backups.sources.${name} unit capture requires a service";
        }
        {
          assertion =
            !databaseCapture source
            || (
              source.capture.database.destinationDir != null
              && (source.capture.type != "sqlite" || source.capture.database.path != null)
            );
          message = "host.backups.sources.${name} database capture is incomplete";
        }
      ]) sources
    )
    ++ lib.optionals server.enable (
      [
        {
          assertion = server.repositories != { };
          message = "host.backups.server.repositories must not be empty";
        }
        {
          assertion = !server.offsite.enable || server.offsite.repositoryRoot != "";
          message = "host.backups.server.offsite.repositoryRoot is required when offsite replication is enabled";
        }
        {
          assertion =
            !server.offsite.enable
            || server.offsite.storageProvider != "b2"
            || server.offsite.bucketName != null;
          message = "host.backups.server.offsite.bucketName is required for B2 usage metrics";
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
            && (
              client.cloud.backend == "local" || (client.cloud.prefix != "" && server.offsite.bucketName != null)
            )
          );
        message = "host.backups.server.repositories.${name}.cloud requires complete repository credentials";
      }) server.repositories
    )
    ++ lib.optional (server.enable && server.offsite.enable) {
      assertion = config.host.network.primaryInterface != null;
      message = "backup cloud-offload policy requires host.network.primaryInterface";
    };
}
