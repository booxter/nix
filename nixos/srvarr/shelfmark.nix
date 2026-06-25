{
  config,
  hostInventory,
  lib,
  ...
}:
let
  idService = hostInventory.servicesById.id;
  accounts = import ./accounts.nix;
  stateDir = "${config.host.srvarrPaths.stateDir}/shelfmark";
  mediaDir = config.host.srvarrPaths.mediaDir;
  user = "shelfmark";
  shelfmarkService = hostInventory.servicesById.shelfmark;
  oidcClientId = "shelfmark";
  oidcIssuerBase = "https://${idService.publicHost}/oauth2/openid/${oidcClientId}";
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
      DISABLE_LOCAL_AUTH = "false";
      FLASK_HOST = "127.0.0.1";
      HIDE_LOCAL_AUTH = "false";
      OIDC_ADMIN_GROUP = "media-admins";
      OIDC_AUTO_PROVISION = "true";
      OIDC_BUTTON_LABEL = "SSO";
      OIDC_CLIENT_ID = oidcClientId;
      OIDC_DISCOVERY_URL = "${oidcIssuerBase}/.well-known/openid-configuration";
      OIDC_GROUP_CLAIM = "media_groups";
      OIDC_SCOPES = "openid,email,profile,media_groups";
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
    serverAliases = [ shelfmarkService.publicHost ];
    mtls.enable = true;
    locationExtraConfig = ''
      proxy_set_header Host ${shelfmarkService.publicHost};
      proxy_set_header X-Forwarded-Host ${shelfmarkService.publicHost};
    '';
  };
}
