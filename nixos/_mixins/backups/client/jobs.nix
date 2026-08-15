{
  backupTopology,
  config,
  lib,
  pkgs,
  ...
}:
let
  model = import ./model.nix { inherit backupTopology config lib; };
  inherit (model) job;
  resticServiceName = "restic-backups-${if job == null then "unused" else job.name}";
  sshHostAlias = "restic-backup-${if job == null then "unused" else job.name}";
  preparationUnits = map (preparation: "${preparation.service}.service") (
    builtins.attrValues (if job == null then { } else job.preparations)
  );
in
{
  config = lib.mkIf (job != null) {
    environment.systemPackages = [ pkgs.restic ];

    services.restic.backups.${job.name} = {
      inherit (job) exclude;
      paths = lib.unique (
        job.paths ++ lib.concatMap (preparation: preparation.paths) (builtins.attrValues job.preparations)
      );
      initialize = true;
      passwordFile = job.destination.passwordFile;
      repository =
        if job.destination.transport == "local" then
          job.destination.repositoryPath
        else
          "sftp:${job.destination.ingestUser}@${sshHostAlias}:${job.destination.repositoryPath}";
      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 8"
        "--keep-monthly 6"
      ];
      runCheck = false;
      timerConfig = {
        OnCalendar = "04:45";
        RandomizedDelaySec = "5m";
        Persistent = true;
      };
      user = job.destination.user;
    };

    programs.ssh.extraConfig = lib.mkIf (job.destination.transport == "sftp") (
      lib.mkAfter ''
        Host ${sshHostAlias}
          HostName ${job.destination.server}
          HostKeyAlias ${job.destination.server}
          IdentityFile ${job.destination.identityFile}
          IdentitiesOnly yes
          BatchMode yes
      ''
    );

    systemd.services.${resticServiceName} = {
      wants = job.destination.dependencyUnits;
      after = job.destination.dependencyUnits ++ preparationUnits;
      requires = preparationUnits;
    };
  };
}
