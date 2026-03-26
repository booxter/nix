{
  config,
  lib,
  pkgs,
  ...
}:
let
  stateRoot = "/data/.state/nixarr";
  backupPaths = [ stateRoot ];
  jellyseerrConfigDir = "${stateRoot}/jellyseerr";
  jellyseerrBackupDir = "${stateRoot}/jellyseerr-backup/latest";
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

  systemd.services.jellyseerr-backup = {
    description = "Create a consistent Jellyseerr SQLite backup artifact";
    before = [ "restic-backups-beast.service" ];
    serviceConfig =
      let
        jellyseerrBackupScript = pkgs.writeShellApplication {
          name = "jellyseerr-backup";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.sqlite
          ];
          text = ''
            set -euo pipefail

            src_dir="${jellyseerrConfigDir}"
            dst_dir="${jellyseerrBackupDir}"
            backup_root="$(dirname "$dst_dir")"
            install -d -m 0750 "$backup_root"
            tmp_dir="$(mktemp -d "${stateRoot}/jellyseerr-backup/.tmp.XXXXXX")"
            trap 'rm -rf "$tmp_dir"' EXIT

            install -d -m 0750 "$dst_dir"

            if [ ! -f "$src_dir/db/db.sqlite3" ]; then
              echo "missing Jellyseerr database at $src_dir/db/db.sqlite3" >&2
              exit 1
            fi

            sqlite3 "$src_dir/db/db.sqlite3" ".backup '$tmp_dir/db.sqlite3'"

            if [ -f "$src_dir/settings.json" ]; then
              install -m 0640 "$src_dir/settings.json" "$tmp_dir/settings.json"
            fi

            date --iso-8601=seconds > "$tmp_dir/created-at.txt"

            mv "$tmp_dir/db.sqlite3" "$dst_dir/db.sqlite3"
            if [ -f "$tmp_dir/settings.json" ]; then
              mv "$tmp_dir/settings.json" "$dst_dir/settings.json"
            fi
            mv "$tmp_dir/created-at.txt" "$dst_dir/created-at.txt"
          '';
        };
      in
      {
        Type = "oneshot";
        User = "root";
        Group = "root";
        ExecStart = lib.getExe jellyseerrBackupScript;
      };
  };

  systemd.timers.jellyseerr-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "05:45";
      RandomizedDelaySec = "0";
    };
  };

  systemd.services.restic-backups-beast = {
    after = [ "jellyseerr-backup.service" ];
    wants = [ "jellyseerr-backup.service" ];
  };
}
