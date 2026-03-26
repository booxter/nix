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
  cloudPruneOpts = [
    "--keep-daily 14"
    "--keep-weekly 8"
    "--keep-monthly 12"
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
      "backup/restic/cloud/password" = { };
      "backup/restic/cloud/b2/applicationKeyId" = { };
      "backup/restic/cloud/b2/applicationKey" = { };
    };

    templates."restic-srvarr-cloud-rclone.conf" = {
      owner = "root";
      group = "root";
      mode = "0400";
      content = ''
        [b2]
        type = s3
        provider = Other
        access_key_id = ${config.sops.placeholder."backup/restic/cloud/b2/applicationKeyId"}
        secret_access_key = ${config.sops.placeholder."backup/restic/cloud/b2/applicationKey"}
        endpoint = s3.us-east-005.backblazeb2.com
        no_check_bucket = true
      '';
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

    cloud = {
      initialize = true;
      passwordFile = config.sops.secrets."backup/restic/cloud/password".path;
      repository = "rclone:b2:ihar-restic-prod/hosts/srvarr";
      rcloneConfigFile = config.sops.templates."restic-srvarr-cloud-rclone.conf".path;
      rcloneOptions = {
        bwlimit = "500k";
      };
      paths = backupPaths;
      exclude = backupExclude;
      pruneOpts = cloudPruneOpts;
      timerConfig = {
        # Stagger cloud backup after the local copy and outside the auto-upgrade window.
        OnCalendar = "07:15";
        RandomizedDelaySec = "45m";
      };
    };
  };
}
