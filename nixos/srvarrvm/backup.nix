{
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
  host.backups.beast = {
    enable = true;
    repoName = "srvarr";
    paths = backupPaths;
    exclude = backupExclude;
    preBackupServices."jellyseerr-backup" = {
      description = "Create a consistent Jellyseerr SQLite backup artifact";
      script = jellyseerrBackupScript;
    };
  };
}
