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
  watchstatePort = 8080;
  watchstateDataDir = "/var/lib/watchstate";
  watchstateUid = 296;
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

  services.restic.backups.beast.paths = [ watchstateDataDir ];

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
