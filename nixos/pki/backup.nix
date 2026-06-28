{ ... }:
let
  kanidmBackupDir = "/var/lib/kanidm/backups";
  stepStateDir = "/var/lib/step-ca";
in
{
  systemd.tmpfiles.rules = [
    "d ${kanidmBackupDir} 0700 kanidm kanidm - -"
  ];

  host.backups.beast = {
    enable = true;
    repoName = "pki";
    paths = [
      kanidmBackupDir
      stepStateDir
    ];
    timerConfig = {
      OnCalendar = "04:45";
      RandomizedDelaySec = "5m";
      Persistent = true;
    };
  };
}
