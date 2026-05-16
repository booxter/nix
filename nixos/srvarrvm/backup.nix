{
  lib,
  pkgs,
  ...
}:
let
  stateRoot = "/data/.state/nixarr";
  backupPaths = [ stateRoot ];
  seerrConfigDir = "${stateRoot}/seerr";
  seerrBackupDir = "${stateRoot}/seerr-backup/latest";
  backupExclude = [
    "${stateRoot}/*/logs"
    "${stateRoot}/*/logs/**"
    "${stateRoot}/*/cache"
    "${stateRoot}/*/cache/**"
  ];
  seerrBackupScript = pkgs.writeShellApplication {
    name = "seerr-backup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.sqlite
    ];
    text = ''
      set -euo pipefail

      src_dir="${seerrConfigDir}"
      dst_dir="${seerrBackupDir}"
      backup_root="$(dirname "$dst_dir")"
      install -d -m 0750 "$backup_root"
      tmp_dir="$(mktemp -d "${stateRoot}/seerr-backup/.tmp.XXXXXX")"
      trap 'rm -rf "$tmp_dir"' EXIT

      install -d -m 0750 "$dst_dir"

      if [ ! -f "$src_dir/db/db.sqlite3" ]; then
        echo "missing Seerr database at $src_dir/db/db.sqlite3" >&2
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
  host.backups.beast = {
    enable = true;
    repoName = "srvarr";
    paths = backupPaths;
    exclude = backupExclude;
    preBackupServices."seerr-backup" = {
      description = "Create a consistent Seerr SQLite backup artifact";
      script = seerrBackupScript;
    };
  };
}
