{
  config,
  hostInventory,
  lib,
  ...
}:
let
  oidc = import ../../lib/oidc-clients.nix { inherit lib hostInventory; };
  accounts = import ./accounts.nix;
  stateDir = "${config.host.srvarrPaths.stateDir}/shelfmark";
  mediaDir = config.host.srvarrPaths.mediaDir;
  user = "shelfmark";
  shelfmarkService = hostInventory.servicesById.shelfmark;
  oidcClientId = oidc.clients.shelfmark.clientId;
in
{
  sops.secrets."shelfmark/oidc/client_secret" = {
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "shelfmark.service" ];
  };

  sops.templates."shelfmark-oidc.env" = {
    owner = user;
    group = "media";
    mode = "0400";
    content = ''
      OIDC_CLIENT_SECRET=${config.sops.placeholder."shelfmark/oidc/client_secret"}
    '';
    restartUnits = [ "shelfmark.service" ];
  };

  services.shelfmark = {
    enable = true;
    environment = {
      AUTH_METHOD = "oidc";
      CONFIG_DIR = stateDir;
      DISABLE_LOCAL_AUTH = "true";
      FLASK_HOST = "127.0.0.1";
      HIDE_LOCAL_AUTH = "true";
      OIDC_ADMIN_GROUP = "media-admins";
      OIDC_AUTO_PROVISION = "true";
      OIDC_BUTTON_LABEL = "SSO";
      OIDC_CLIENT_ID = oidcClientId;
      OIDC_DISCOVERY_URL = oidc.discoveryUrl oidcClientId;
      OIDC_GROUP_CLAIM = "media_groups";
      OIDC_SCOPES = lib.concatStringsSep "," (oidc.scopeWith [ "media_groups" ]);
      OIDC_USE_ADMIN_GROUP = "true";
      SESSION_COOKIE_SECURE = "true";
    };
  };

  systemd.tmpfiles.rules = [
    "d '${stateDir}' 0700 ${user} root - -"
  ];

  systemd.services.shelfmark = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };

  systemd.services.shelfmark.serviceConfig = {
    EnvironmentFile = config.sops.templates."shelfmark-oidc.env".path;
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
