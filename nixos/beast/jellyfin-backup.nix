{
  config,
  lib,
  pkgs,
  ...
}:
let
  jellyfinBackupDir = "/var/lib/jellyfin/data/backups";
  stagingDir = "/volume2/backups/staging/jellyfin";
  keepLocalBackups = 7;
  keepJellyfinSourceBackups = 1;
  backupApiKeySecret = "jellyfin/apiKey";
  localRepoPasswordSecret = "backup/restic/beast/cloud/localPassword";
  localRepo = "/volume2/backups/restic-prod/hosts/beast";
  jellyfinBackupScript = pkgs.writeShellApplication {
    name = "jellyfin-built-in-backup";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      findutils
      gnugrep
      gawk
      jq
    ];
    text = ''
      set -euo pipefail

      backup_dir="${jellyfinBackupDir}"
      staging_dir="${stagingDir}"
      keep="${toString keepLocalBackups}"
      keep_source="${toString keepJellyfinSourceBackups}"
      api_key="$(tr -d '\n' < ${lib.escapeShellArg config.sops.secrets.${backupApiKeySecret}.path})"

      response="$(
        curl \
          --silent \
          --show-error \
          --fail-with-body \
          --request POST \
          --url http://127.0.0.1:8096/Backup/Create \
          --header "Authorization: MediaBrowser Token=\"$api_key\"" \
          --header "X-Emby-Token: $api_key" \
          --header 'Content-Type: application/json' \
          --data '{"Database":true,"Metadata":false,"Subtitles":false,"Trickplay":false}'
      )"

      created_path="$(printf '%s' "$response" | jq -r '.Path // .path // empty')"
      if [ -z "$created_path" ] || [ ! -f "$created_path" ]; then
        echo "Jellyfin backup API did not return a valid archive path" >&2
        printf '%s\n' "$response" >&2
        exit 1
      fi

      install -d -m 0750 -o root -g restic-cloud "$staging_dir"
      install -m 0640 -o root -g restic-cloud "$created_path" "$staging_dir/$(basename "$created_path")"

      mapfile -t archives < <(
        find "$staging_dir" -maxdepth 1 -type f -name 'jellyfin-backup-*.zip' -printf '%T@ %p\n' \
          | sort -nr \
          | awk '{ print $2 }'
      )

      if [ "''${#archives[@]}" -le "$keep" ]; then
        exit 0
      fi

      for old_archive in "''${archives[@]:$keep}"; do
        rm -f -- "$old_archive"
      done

      mapfile -t source_archives < <(
        find "$backup_dir" -maxdepth 1 -type f -name 'jellyfin-backup-*.zip' -printf '%T@ %p\n' \
          | sort -nr \
          | awk '{ print $2 }'
      )

      if [ "''${#source_archives[@]}" -le "$keep_source" ]; then
        exit 0
      fi

      for old_archive in "''${source_archives[@]:$keep_source}"; do
        rm -f -- "$old_archive"
      done
    '';
  };
in
{
  sops = {
    secrets = {
      ${backupApiKeySecret} = {
        owner = "root";
        group = "root";
        mode = "0400";
      };
    };
  };

  systemd.services.jellyfin-built-in-backup = {
    description = "Create a built-in Jellyfin backup archive";
    restartIfChanged = false;
    stopIfChanged = false;
    before = [ "restic-backups-beast.service" ];
    wants = [
      "jellyfin.service"
      "sops-install-secrets.service"
    ];
    after = [
      "jellyfin.service"
      "sops-install-secrets.service"
    ];
    unitConfig.RequiresMountsFor = [
      jellyfinBackupDir
      stagingDir
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = lib.getExe jellyfinBackupScript;
    };
  };

  services.restic.backups.beast = {
    initialize = true;
    user = "restic-cloud";
    passwordFile = config.sops.secrets.${localRepoPasswordSecret}.path;
    repository = localRepo;
    paths = [ stagingDir ];
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 8"
      "--keep-monthly 6"
    ];
    timerConfig = {
      OnCalendar = "04:30";
      RandomizedDelaySec = "15m";
      Persistent = true;
    };
  };

  systemd.services.restic-backups-beast = {
    restartIfChanged = false;
    stopIfChanged = false;
    after = [ "jellyfin-built-in-backup.service" ];
    wants = [ "jellyfin-built-in-backup.service" ];
    requires = [ "jellyfin-built-in-backup.service" ];
  };
}
