{ config, ... }:
let
  kanidmBackupDir = "/var/lib/kanidm/backups";
  stepStateDir = "/var/lib/step-ca";
  resticPasswordSecret = "backup/restic/local/password";
  resticSshKeySecret = "backup/restic/local/ssh/privateKey";
in
{
  systemd.tmpfiles.rules = [
    "d ${kanidmBackupDir} 0700 kanidm kanidm - -"
  ];

  sops.secrets = {
    ${resticPasswordSecret} = { };
    ${resticSshKeySecret} = {
      owner = "root";
      group = "root";
      mode = "0400";
    };
  };

  host.backups.jobs.beast = {
    title = "Restic To Beast";
    paths = [
      kanidmBackupDir
      stepStateDir
    ];
    timerConfig = {
      OnCalendar = "04:45";
      RandomizedDelaySec = "5m";
      Persistent = true;
    };
    repository = {
      type = "sftp";
      path = "/volume2/backups/restic-prod/hosts/pki";
      passwordFile = config.sops.secrets.${resticPasswordSecret}.path;
      dependencyUnits = [ "sops-install-secrets.service" ];
      sftp = {
        host = "beast";
        user = "restic-pki";
        identityFile = config.sops.secrets.${resticSshKeySecret}.path;
      };
    };
  };
}
