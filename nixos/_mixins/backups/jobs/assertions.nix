{ config, lib, ... }:
let
  jobs = config.host.backups.jobs;
  preparationPaths =
    job: lib.concatMap (preparation: preparation.paths) (builtins.attrValues job.preparations);
in
{
  assertions = lib.concatLists (
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
  );
}
