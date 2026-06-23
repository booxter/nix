{
  lib,
  pkgs,
  ...
}:
let
  paperlessBackupDir = "/var/lib/paperless-backup/latest";
  paperlessDataDir = "/var/lib/paperless";
  paperlessGptStateDir = "/var/lib/paperless-gpt";
  paperlessStoragePath = "/data/paperless";
  backupPaths = [
    paperlessBackupDir
    paperlessDataDir
    paperlessGptStateDir
    paperlessStoragePath
    "/var/lib/vikunja/files"
    "/var/lib/vikunja-backup/latest"
  ];
  paperlessBackupScript = pkgs.writeShellApplication {
    name = "paperless-backup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.postgresql
      pkgs.util-linux
    ];
    text = ''
      set -euo pipefail

      dst_dir="${paperlessBackupDir}"
      backup_root="$(dirname "$dst_dir")"

      install -d -m 0750 "$backup_root"
      tmp_dir="$(mktemp -d "/var/lib/paperless-backup/.tmp.XXXXXX")"
      trap 'rm -rf "$tmp_dir"' EXIT

      install -d -m 0750 "$dst_dir"

      runuser -u postgres -- pg_dump --format=custom --file="$tmp_dir/paperless.dump" paperless
      date --iso-8601=seconds > "$tmp_dir/created-at.txt"

      mv "$tmp_dir/paperless.dump" "$dst_dir/paperless.dump"
      mv "$tmp_dir/created-at.txt" "$dst_dir/created-at.txt"
    '';
  };
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
  host.backups.beast = {
    enable = true;
    repoName = "orgvm";
    paths = backupPaths;
    preBackupServices."paperless-backup" = {
      description = "Create a consistent Paperless PostgreSQL backup artifact";
      script = paperlessBackupScript;
      unitConfig = {
        After = [ "postgresql.service" ];
        RequiresMountsFor = [
          paperlessBackupDir
          paperlessDataDir
        ];
      };
    };
    preBackupServices."vikunja-backup" = {
      description = "Create a consistent Vikunja SQLite backup artifact";
      script = vikunjaBackupScript;
    };
  };
}
