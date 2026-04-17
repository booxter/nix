{
  config,
  lib,
  pkgs,
  ...
}:
let
  backupPaths = [
    "/var/lib/vikunja/files"
    "/var/lib/vikunja-backup/latest"
  ];
  localPruneOpts = [
    "--keep-daily 7"
    "--keep-weekly 8"
    "--keep-monthly 6"
  ];
  localSshKey = config.sops.secrets."backup/restic/local/ssh/privateKey".path;
in
{
  sops.secrets = {
    "backup/restic/local/password" = { };
    "backup/restic/local/ssh/privateKey" = {
      owner = "root";
      group = "root";
      mode = "0400";
    };
  };

  programs.ssh.extraConfig = lib.mkAfter ''
    Host beast
      IdentityFile ${localSshKey}
      IdentitiesOnly yes
  '';

  services.restic.backups.beast = {
    initialize = true;
    passwordFile = config.sops.secrets."backup/restic/local/password".path;
    repository = "sftp:restic-orgvm@beast:/volume2/backups/restic-prod/hosts/orgvm";
    paths = backupPaths;
    pruneOpts = localPruneOpts;
    timerConfig = {
      # Run after the 03:30±15m upgrade/reboot work has settled.
      OnCalendar = "04:30";
      RandomizedDelaySec = "15m";
    };
  };

  systemd.services.vikunja-backup = {
    description = "Create a consistent Vikunja SQLite backup artifact";
    before = [ "restic-backups-beast.service" ];
    serviceConfig =
      let
        vikunjaBackupScript = pkgs.writeShellApplication {
          name = "vikunja-backup";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.sqlite
          ];
          text = ''
            set -euo pipefail

            src_db="/var/lib/vikunja/vikunja.db"
            dst_dir="/var/lib/vikunja-backup/latest"
            backup_root="$(dirname "$dst_dir")"

            install -d -m 0750 "$backup_root"
            tmp_dir="$(mktemp -d "/var/lib/vikunja-backup/.tmp.XXXXXX")"
            trap 'rm -rf "$tmp_dir"' EXIT

            install -d -m 0750 "$dst_dir"

            if [ ! -f "$src_db" ]; then
              echo "missing Vikunja database at $src_db" >&2
              exit 1
            fi

            sqlite3 "$src_db" ".backup '$tmp_dir/vikunja.db'"
            date --iso-8601=seconds > "$tmp_dir/created-at.txt"

            mv "$tmp_dir/vikunja.db" "$dst_dir/vikunja.db"
            mv "$tmp_dir/created-at.txt" "$dst_dir/created-at.txt"
          '';
        };
      in
      {
        Type = "oneshot";
        User = "root";
        Group = "root";
        ExecStart = lib.getExe vikunjaBackupScript;
      };
  };

  systemd.timers.vikunja-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "04:15";
      RandomizedDelaySec = "0";
    };
  };

  systemd.services.restic-backups-beast = {
    after = [ "vikunja-backup.service" ];
    wants = [ "vikunja-backup.service" ];
  };
}
