{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
  writablePaths = lib.unique (
    [
      cfg.stateDir
      model.ebooks.path
    ]
    ++ lib.optional (model.audiobooks != null) model.audiobooks.path
    ++ lib.optional (model.torrent != null) model.torrent.path
    ++ lib.optional (model.usenet != null) model.usenet.path
    ++ lib.optional cfg.integrations.ebookConverter.enable model.converter.stateDir
  );
in
{
  config = lib.mkIf cfg.enable {
    services.shelfmark = {
      enable = true;
      package = cfg.package;
      environment = {
        AUTH_METHOD = "oidc";
        CONFIG_DIR = cfg.stateDir;
        DISABLE_LOCAL_AUTH = "true";
        FLASK_HOST = "127.0.0.1";
        FLASK_PORT = cfg.port;
        HIDE_LOCAL_AUTH = "true";
        INGEST_DIR = model.ebooks.path;
        OIDC_ADMIN_GROUP = model.ssoApplication.adminGroup;
        OIDC_AUTO_PROVISION = "true";
        OIDC_BUTTON_LABEL = "SSO";
        OIDC_CLIENT_ID = model.oidcClient.clientId;
        OIDC_DISCOVERY_URL = model.oidcClient.discoveryUrl;
        OIDC_GROUP_CLAIM = "shelfmark_groups";
        OIDC_SCOPES = lib.concatStringsSep "," (model.oidcScopes ++ [ "shelfmark_groups" ]);
        OIDC_USE_ADMIN_GROUP = "true";
        SESSION_COOKIE_SECURE = "true";
      }
      // lib.optionalAttrs (model.audiobooks != null) {
        DESTINATION_AUDIOBOOK = model.audiobooks.path;
      }
      // lib.optionalAttrs (model.audiobookshelfService != null) {
        AUDIOBOOK_LIBRARY_URL = model.audiobookshelfService.public.url;
      };
    };

    systemd.services.shelfmark = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
      serviceConfig = {
        EnvironmentFile = config.sops.templates."shelfmark.env".path;
        Group = cfg.group;
        ReadWritePaths = writablePaths;
        StateDirectory = lib.mkForce "";
        UMask = lib.mkForce "0002";
        User = cfg.user;
      };
    };

    users.users.${cfg.user} = {
      group = cfg.group;
      home = "/var/empty";
      isSystemUser = true;
    };
  };
}
