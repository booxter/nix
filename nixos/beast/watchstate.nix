{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  ociImages = import ../../lib/oci-images.nix { inherit pkgs; };
  watchstateImage = ociImages.watchstate.ref;
  watchstateImageFile = ociImages.watchstate.imageFile;
  watchstateHostName = "watchstate.${hostInventory.site.lan.domain}";
  watchstateSso = hostInventory.sso.applications.watchstate;
  watchstateSystemUser = watchstateSso.bootstrapOwner;
  watchstateSystemAccount = hostInventory.sso.users.${watchstateSystemUser};
  watchstatePort = hostInventory.site.ports.watchstate;
  watchstateDataDir = "/var/lib/watchstate";
  watchstateBackupStagingDir = "/volume2/backups/staging/watchstate";
  watchstateUid = 296;
  watchstateBackupScript = pkgs.writeShellApplication {
    name = "watchstate-native-backup";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gawk
      gnutar
      podman
      rsync
      sqlite
    ];
    text = ''
      set -euo pipefail

      data_dir=${lib.escapeShellArg watchstateDataDir}
      staging_dir=${lib.escapeShellArg watchstateBackupStagingDir}
      archive_name="watchstate-backup-$(date --utc +%Y%m%dT%H%M%SZ).tar.gz"

      install -d -m 0750 -o root -g restic-cloud "$staging_dir"
      work_dir="$(mktemp -d --tmpdir="$staging_dir" .watchstate-backup.XXXXXX)"
      trap 'rm -rf "$work_dir"' EXIT
      install -d -m 0700 "$work_dir/state/db"

      podman exec watchstate \
        /opt/bin/console state:backup --keep --sync-requests --no-interaction -v

      rsync \
        --archive \
        --exclude=/db/watchstate_v02.db \
        --exclude=/db/watchstate_v02.db-shm \
        --exclude=/db/watchstate_v02.db-wal \
        "$data_dir/" \
        "$work_dir/state/"

      sqlite3 "$data_dir/db/watchstate_v02.db" \
        ".backup '$work_dir/state/db/watchstate_v02.db'"

      tar --create --gzip --file "$work_dir/$archive_name" --directory "$work_dir" state
      install \
        -m 0640 \
        -o root \
        -g restic-cloud \
        "$work_dir/$archive_name" \
        "$staging_dir/$archive_name"

      mapfile -t archives < <(
        find "$staging_dir" -maxdepth 1 -type f -name 'watchstate-backup-*.tar.gz' -printf '%T@ %p\n' \
          | sort -nr \
          | awk '{ print $2 }'
      )
      if [ "''${#archives[@]}" -gt 7 ]; then
        rm -f -- "''${archives[@]:7}"
      fi
    '';
  };
in
{
  users.groups.watchstate.gid = watchstateUid;
  users.users.watchstate = {
    description = "WatchState service user";
    isSystemUser = true;
    group = "watchstate";
    uid = watchstateUid;
    home = watchstateDataDir;
    createHome = false;
  };

  sops.secrets."watchstate/system/password" = {
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [
      "watchstate-password-env.service"
      "podman-watchstate.service"
    ];
  };

  systemd.services.watchstate-password-env = {
    description = "Render the WatchState authentication environment";
    requires = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
    before = [ "podman-watchstate.service" ];
    path = [
      pkgs.apacheHttpd
      pkgs.coreutils
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Keep the credentials outside the generated Podman unit's
      # /run/watchstate directory: systemd removes that directory whenever the
      # container stops, while this oneshot remains active and is not rerun.
      RuntimeDirectory = "watchstate-auth";
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
    };
    script = ''
      env_file="$RUNTIME_DIRECTORY/auth.env"
      tmp_file="$env_file.tmp"
      trap 'rm -f "$tmp_file"' EXIT

      password_hash="$(
        htpasswd \
          -niBC 12 \
          watchstate \
          < ${config.sops.secrets."watchstate/system/password".path}
      )"
      password_hash="''${password_hash#watchstate:}"

      {
        printf 'WS_SYSTEM_USER=%s\n' ${lib.escapeShellArg watchstateSystemUser}
        printf 'WS_SYSTEM_PASSWORD=ws_hash@:%s\n' "$password_hash"
      } > "$tmp_file"

      chmod 0400 "$tmp_file"
      mv "$tmp_file" "$env_file"
      trap - EXIT
    '';
  };

  virtualisation.oci-containers = {
    backend = "podman";
    containers.watchstate = {
      image = watchstateImage;
      imageFile = watchstateImageFile;
      pull = "never";
      user = "${toString watchstateUid}:${toString watchstateUid}";
      environment = {
        TZ = "America/New_York";
        # Webhooks provide low-latency updates, while these staggered jobs
        # reconcile events that Jellyfin or WatchState may have missed. Import
        # first so the following export works from the freshest combined state.
        WS_CRON_IMPORT = "true";
        WS_CRON_IMPORT_AT = "0 */12 * * *";
        WS_CRON_EXPORT = "true";
        WS_CRON_EXPORT_AT = "30 */12 * * *";
        # Disable WatchState's cron trigger: watchstate-native-backup.service
        # invokes the same native backup immediately before Restic, ensuring
        # the latest archive is included and the outcome is monitored.
        WS_CRON_BACKUP = "false";
        # Serialize full export comparisons and state writes so large syncs do
        # not exhaust the reverse proxy or Jellyfin API. WatchState 1.9.2 does
        # not apply this switch to incremental Jellyfin metadata reads, so each
        # exported Jellyfin backend must also set options.client.http_version
        # to 1.1. Disabling HTTP/2 multiplexing makes WatchState's built-in
        # per-host connection limit effective for those requests.
        WS_HTTP_SYNC_REQUESTS = "true";
      };
      environmentFiles = [ "/run/watchstate-auth/auth.env" ];
      extraOptions = [
        "--cap-drop=all"
        "--security-opt=no-new-privileges"
      ];
      ports = [ "127.0.0.1:${toString watchstatePort}:${toString watchstatePort}" ];
      volumes = [ "${watchstateDataDir}:/config:rw" ];
    };
  };

  systemd.tmpfiles.rules = [
    "d ${watchstateDataDir} 0700 watchstate watchstate - -"
  ];

  systemd.services.podman-watchstate = {
    requires = [ "watchstate-password-env.service" ];
    wants = [
      "network-online.target"
    ];
    after = [
      "network-online.target"
      "watchstate-password-env.service"
    ];
    unitConfig.RequiresMountsFor = [ watchstateDataDir ];
  };

  systemd.services.watchstate-native-backup = {
    description = "Create a native WatchState backup archive";
    restartIfChanged = false;
    stopIfChanged = false;
    before = [ "restic-backups-beast.service" ];
    requires = [ "podman-watchstate.service" ];
    after = [ "podman-watchstate.service" ];
    unitConfig.RequiresMountsFor = [ watchstateBackupStagingDir ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = lib.getExe watchstateBackupScript;
      TimeoutStartSec = "2h";
    };
  };

  systemd.services.restic-backups-beast = {
    after = [ "watchstate-native-backup.service" ];
    wants = [ "watchstate-native-backup.service" ];
    requires = [ "watchstate-native-backup.service" ];
  };

  services.restic.backups.beast.paths = [ watchstateBackupStagingDir ];

  host.observability.backupMetrics.jobs.watchstate-native-backup = {
    service = "watchstate-native-backup";
    title = "WatchState Native Backup";
    phase = "prep";
  };

  host.internalHttps.services.watchstate = {
    enable = true;
    upstream = "http://127.0.0.1:${toString watchstatePort}";
    locationExtraConfig = ''
      proxy_read_timeout 300s;
      proxy_send_timeout 300s;
    '';
  };

  host.sso.oauth2ProxyGates.watchstate = {
    enable = true;
    clientId = "watchstate";
    httpAddress = "http://127.0.0.1:4182";
    cookieName = "_watchstate_sso";
    allowedGroups = [ watchstateSso.adminGroup ];
    groupClaim = "media_groups";
    whitelistDomains = [ watchstateHostName ];
    internalHttpsServiceNames = [ "watchstate" ];
    # WatchState uses X-User for its own identity selection.
    authRequestHeaders = [ ];
    # WatchState's frontend uses Authorization for its own API session.
    clearAuthorizationHeader = false;
    probeLocationsByName.watchstate."= /v1/api/system/healthcheck" = {
      proxyPass = "http://127.0.0.1:${toString watchstatePort}";
      recommendedProxySettings = true;
      extraConfig = ''
        auth_request off;
      '';
    };
  };

  assertions = [
    {
      assertion = builtins.elem watchstateSso.adminGroup watchstateSystemAccount.groups;
      message = "The WatchState bootstrap owner must belong to its SSO admin group.";
    }
    {
      assertion = builtins.match "[a-z0-9_]+" watchstateSystemUser != null;
      message = "The WatchState bootstrap owner must be a valid WatchState username.";
    }
  ];
}
