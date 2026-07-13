{
  hostInventory,
  pkgs,
  ...
}:
let
  ociImages = import ../../lib/oci-images.nix { inherit pkgs; };
  watchstateImage = ociImages.watchstate.ref;
  watchstateImageFile = ociImages.watchstate.imageFile;
  watchstateHostName = "watchstate.${hostInventory.site.lan.domain}";
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
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
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
    allowedGroups = [ "media-admins" ];
    groupClaim = "media_groups";
    whitelistDomains = [ watchstateHostName ];
    internalHttpsServiceNames = [ "watchstate" ];
    # WatchState's frontend uses Authorization for its own API session.
    clearAuthorizationHeader = false;
  };
}
