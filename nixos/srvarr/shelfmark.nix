{
  config,
  hostInventory,
  lib,
  ...
}:
let
  accounts = import ./accounts.nix;
  stateDir = "${config.host.srvarrPaths.stateDir}/shelfmark";
  mediaDir = config.host.srvarrPaths.mediaDir;
  user = "shelfmark";
  shelfmarkService = hostInventory.servicesById.shelfmark;
in
{
  services.shelfmark = {
    enable = true;
    environment = {
      AUTH_METHOD = "proxy";
      CONFIG_DIR = stateDir;
      FLASK_HOST = "127.0.0.1";
      PROXY_AUTH_ADMIN_GROUP_HEADER = "X-Groups";
      PROXY_AUTH_ADMIN_GROUP_NAME = "media-admins";
      PROXY_AUTH_LOGOUT_URL = "/oauth2/sign_out";
      PROXY_AUTH_USER_HEADER = "X-User";
      SESSION_COOKIE_SECURE = "true";
    };
  };

  systemd.tmpfiles.rules = [
    "d '${stateDir}' 0700 ${user} root - -"
  ];

  systemd.services.shelfmark.serviceConfig = {
    Group = "media";
    ReadWritePaths = [
      stateDir
      mediaDir
    ];
    StateDirectory = lib.mkForce "";
    User = user;
  };

  users.users.${user} = {
    group = "media";
    home = "/var/empty";
    isSystemUser = true;
    uid = accounts.uids.shelfmark;
  };

  host.internalHttps.services.shelfmark = {
    enable = true;
    upstream = "http://127.0.0.1:${toString config.services.shelfmark.environment.FLASK_PORT}";
    publicAliases = [ shelfmarkService.publicHost ];
    mtls.enable = true;
    recommendedProxySettings = false;
    locationExtraConfig = ''
      proxy_set_header Host ${shelfmarkService.publicHost};
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Forwarded-Host ${shelfmarkService.publicHost};
      proxy_set_header X-Forwarded-Server $hostname;
    '';
  };
}
