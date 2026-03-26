{ config, lib, ... }:
let
  stateRoot = "/data/.state/nixarr";
  backupPaths = [ stateRoot ];
  backupExclude = [
    "${stateRoot}/*/logs"
    "${stateRoot}/*/logs/**"
    "${stateRoot}/*/cache"
    "${stateRoot}/*/cache/**"
  ];
  localPruneOpts = [
    "--keep-daily 7"
    "--keep-weekly 8"
    "--keep-monthly 6"
  ];
  localSshKey = config.sops.secrets."backup/restic/local/ssh/privateKey".path;
in
{
  sops = {
    secrets = {
      "backup/restic/local/password" = { };
      "backup/restic/local/ssh/privateKey" = {
        owner = "root";
        group = "root";
        mode = "0400";
      };
    };
  };

  programs.ssh = {
    extraConfig = lib.mkAfter ''
      Host beast
        IdentityFile ${localSshKey}
        IdentitiesOnly yes
    '';
  };
  services.restic.backups = {
    beast = {
      initialize = true;
      passwordFile = config.sops.secrets."backup/restic/local/password".path;
      repository = "sftp:restic-srvarr@beast:/volume2/backups/restic-prod/hosts/srvarr";
      paths = backupPaths;
      exclude = backupExclude;
      pruneOpts = localPruneOpts;
      timerConfig = {
        # Keep backups outside the 01:00-05:00 reboot window used by auto-upgrades.
        OnCalendar = "06:15";
        RandomizedDelaySec = "30m";
      };
    };
  };
}
