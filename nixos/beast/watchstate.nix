{
  beastPkgs,
  config,
  hostInventory,
  lib,
  pkgs,
  utils,
  ...
}:
let
  mediaPaths = import ./media-paths.nix;
  ociImages = import ../../lib/oci-images { inherit pkgs; };
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
  renderAuthCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' beastPkgs.watchstate-tools "watchstate-render-auth")
    "--system-user"
    watchstateSystemUser
    "--password-file"
    config.sops.secrets."watchstate/system/password".path
    "--output"
    "/run/watchstate-auth/auth.env"
  ];
  backupCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' beastPkgs.watchstate-tools "watchstate-native-backup")
    "--data-dir"
    watchstateDataDir
    "--staging-dir"
    watchstateBackupStagingDir
    "--keep"
    "7"
  ];
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
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Keep the credentials outside the generated Podman unit's
      # /run/watchstate directory: systemd removes that directory whenever the
      # container stops, while this oneshot remains active and is not rerun.
      RuntimeDirectory = "watchstate-auth";
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
      ExecStart = renderAuthCommand;
    };
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
        # oauth2-proxy remains the browser-facing authentication boundary.
        # Trust nginx's loopback connection so WatchState mints its internal
        # token after SSO instead of prompting for a second password.
        WS_TRUST_LOCAL = "true";
        # Webhooks provide low-latency updates, while these staggered jobs
        # reconcile events that Jellyfin or WatchState may have missed. Import
        # first so the following export works from the freshest combined state.
        WS_CRON_IMPORT = "true";
        WS_CRON_IMPORT_AT = "0 */12 * * *";
        WS_CRON_EXPORT = "true";
        WS_CRON_EXPORT_AT = "30 */12 * * *";
        # Generate the consolidated backend/path audit after the midnight
        # import and enable file checks against the read-only library mount.
        WS_CRON_MEDIA_HEALTH = "true";
        WS_CRON_MEDIA_HEALTH_AT = "0 5 * * *";
        WS_MEDIA_HEALTH_CHECK_FILES = "true";
        # Disable WatchState's cron trigger: watchstate-native-backup.service
        # invokes the same native backup immediately before Restic, ensuring
        # the latest archive is included and the outcome is monitored.
        WS_CRON_BACKUP = "false";
        # Serialize full export comparisons and state writes so large syncs do
        # not exhaust the reverse proxy or Jellyfin API. WatchState does
        # not apply this switch to incremental Jellyfin metadata reads, so each
        # exported Jellyfin backend must also set options.client.http_version
        # to 1.1. Disabling HTTP/2 multiplexing makes WatchState's built-in
        # per-host connection limit effective for those requests.
        WS_HTTP_SYNC_REQUESTS = "true";
      };
      environmentFiles = [ "/run/watchstate-auth/auth.env" ];
      extraOptions = [
        "--cap-drop=all"
        # The image probes before WatchState finishes initializing. Podman
        # exposes that expected startup miss as a failed transient systemd
        # unit, which makes NixOS activation report a false failure. The
        # backend endpoint remains covered by the external probe below.
        "--no-healthcheck"
        "--security-opt=no-new-privileges"
      ];
      ports = [ "127.0.0.1:${toString watchstatePort}:${toString watchstatePort}" ];
      volumes = [
        "${watchstateDataDir}:/config:rw"
        "${mediaPaths.sourceLibraryRoot}:${mediaPaths.jellyfinLibraryRoot}:ro"
      ];
    };
  };

  systemd.tmpfiles.rules = [
    "d ${watchstateDataDir} 0700 watchstate watchstate - -"
    "d ${watchstateBackupStagingDir} 0750 root restic-cloud - -"
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
    unitConfig.RequiresMountsFor = [
      watchstateDataDir
      mediaPaths.sourceLibraryRoot
    ];
  };

  systemd.services.watchstate-native-backup = {
    description = "Create a native WatchState backup archive";
    restartIfChanged = false;
    stopIfChanged = false;
    before = [ "restic-backups-beast.service" ];
    requires = [
      "podman-watchstate.service"
      "podman.socket"
    ];
    after = [
      "podman-watchstate.service"
      "podman.socket"
    ];
    unitConfig.RequiresMountsFor = [ watchstateBackupStagingDir ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "restic-cloud";
      UMask = "0027";
      ExecStart = backupCommand;
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
