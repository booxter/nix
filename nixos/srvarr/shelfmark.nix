{
  config,
  hostInventory,
  lib,
  srvarrPkgs,
  ...
}:
let
  accounts = import ./accounts.nix;
  stateDir = "${config.host.srvarrPaths.stateDir}/shelfmark";
  mediaDir = config.host.srvarrPaths.mediaDir;
  booksDir = "${mediaDir}/library/books";
  ebookConverterStateDir = "/var/lib/ebook-converter";
  user = "shelfmark";
  shelfmarkService = hostInventory.servicesById.shelfmark;
  oidcClient = config.host.sso.oidc.clients.shelfmark;
  oidcScopes = config.host.sso.oidc.baseScopes;
in
{
  host.sso.oidc.registrations.shelfmark = {
    displayName = "Shelfmark";
    originUrls = [ "${shelfmarkService.url}/api/auth/oidc/callback" ];
    originLanding = "${shelfmarkService.url}/";
    scopeMaps = {
      "media-admins" = oidcScopes ++ [ "media_groups" ];
      "media-users" = oidcScopes ++ [ "media_groups" ];
    };
    claimMaps.media_groups.valuesByGroup = {
      "media-admins" = [ "media-admins" ];
      "media-users" = [ "media-users" ];
    };
    secret = {
      sopsKey = "shelfmark/oidc/client_secret";
      name = "shelfmark/oidc/client_secret";
      restartUnits = [ "shelfmark.service" ];
    };
  };

  sops.templates."shelfmark-oidc.env" = {
    owner = user;
    group = "media";
    mode = "0400";
    content = ''
      OIDC_CLIENT_SECRET=${oidcClient.secret.placeholder}
    '';
    restartUnits = [ "shelfmark.service" ];
  };

  services.shelfmark = {
    enable = true;
    environment = {
      AUTH_METHOD = "oidc";
      CONFIG_DIR = stateDir;
      CUSTOM_SCRIPT = "${srvarrPkgs.ebook-converter}/bin/shelfmark-ebook-converter-hook";
      CUSTOM_SCRIPT_JSON_PAYLOAD = "true";
      CUSTOM_SCRIPT_PATH_MODE = "absolute";
      DISABLE_LOCAL_AUTH = "true";
      EBOOK_CONVERTER_LIBRARY_ROOT = booksDir;
      EBOOK_CONVERTER_STATE_DIR = ebookConverterStateDir;
      FLASK_HOST = "127.0.0.1";
      HIDE_LOCAL_AUTH = "true";
      OIDC_ADMIN_GROUP = "media-admins";
      OIDC_AUTO_PROVISION = "true";
      OIDC_BUTTON_LABEL = "SSO";
      OIDC_CLIENT_ID = oidcClient.clientId;
      OIDC_DISCOVERY_URL = oidcClient.discoveryUrl;
      OIDC_GROUP_CLAIM = "media_groups";
      OIDC_SCOPES = lib.concatStringsSep "," (oidcScopes ++ [ "media_groups" ]);
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
      ebookConverterStateDir
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
