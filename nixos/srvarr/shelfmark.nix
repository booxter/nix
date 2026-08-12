{
  config,
  lib,
  srvarrPkgs,
  ...
}:
let
  accounts = import ./accounts.nix { hostAccounts = config.host.accounts; };
  stateDir = "/data/.state/nixarr/shelfmark";
  mediaDir = config.host.storage.claims.media.mountPoint;
  booksDir = "${mediaDir}/library/books";
  ebookConverterStateDir = "/var/lib/ebook-converter";
  user = "shelfmark";
  shelfmarkService = config.host.web.services.shelfmark;
  oidcClient = config.host.sso.oidc.clients.shelfmark;
  oidcScopes = config.host.sso.oidc.baseScopes;
in
{
  host.storage.claims.media.attachments.shelfmark.unit = "shelfmark";

  host.backups.sources.shelfmark = {
    title = "Shelfmark";
    paths = [ "${stateDir}/plugins" ];
    capture = {
      type = "sqlite";
      database = {
        path = "${stateDir}/users.db";
        destinationDir = "/data/.state/nixarr/shelfmark-backup/latest";
        extraCopies = [
          {
            source = "${stateDir}/.flask_secret";
            mode = "0600";
            optional = false;
          }
          {
            source = "${stateDir}/settings.json";
            optional = false;
          }
        ];
      };
    };
  };

  host.web.services.shelfmark.auth = {
    mode = "oidc";
    oidcRegistration = {
      displayName = "Shelfmark";
      originUrls = [ "${shelfmarkService.public.url}/api/auth/oidc/callback" ];
      originLanding = "${shelfmarkService.public.url}/";
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
    UMask = lib.mkForce "0002";
    User = user;
  };

  users.users.${user} = {
    group = "media";
    home = "/var/empty";
    isSystemUser = true;
    uid = accounts.uids.shelfmark;
  };

  host.web.services.shelfmark = {
    enable = true;
    upstream = "http://127.0.0.1:${toString config.services.shelfmark.environment.FLASK_PORT}";
    public = {
      enable = true;
      hostName = "shelf.${config.host.network.publicDomain}";
    };
    health.frontend = {
      enable = true;
      path = "/api/health";
    };
    observability.importance = "important";
    presentation.dashboard = {
      enable = true;
      section = "user";
    };
    internal = {
      recommendedProxySettings = false;
      locationExtraConfig = ''
        proxy_set_header Host ${shelfmarkService.public.hostName};
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host ${shelfmarkService.public.hostName};
        proxy_set_header X-Forwarded-Server $hostname;
      '';
    };
  };
}
