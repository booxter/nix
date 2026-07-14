{
  config,
  hostInventory,
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
  };

  sops.templates."watchstate.env" = {
    owner = "root";
    group = "root";
    mode = "0400";
    content = ''
      WS_SYSTEM_USER=${watchstateSystemUser}
      WS_SYSTEM_PASSWORD=${config.sops.placeholder."watchstate/system/password"}
    '';
    restartUnits = [ "podman-watchstate.service" ];
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
      };
      environmentFiles = [ config.sops.templates."watchstate.env".path ];
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
    wants = [
      "network-online.target"
      "sops-install-secrets.service"
    ];
    after = [
      "network-online.target"
      "sops-install-secrets.service"
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
