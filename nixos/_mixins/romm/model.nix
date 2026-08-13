{
  config,
  lib,
  outputs,
  pkgs,
}:
let
  cfg = config.host.romm;
  storage = import ../storage/resources/model.nix { inherit config lib outputs; };
  claim = storage.localClaims.${cfg.storage.claim} or null;
  account = config.host.accounts.users.${cfg.user} or null;
  ssoApplication = config.host.sso.applications.${cfg.sso.application} or null;
  accessGroups =
    if ssoApplication == null then
      [ ]
    else
      builtins.filter (group: group != null) [
        ssoApplication.adminGroup
        ssoApplication.editorGroup
        ssoApplication.viewerGroup
      ];
  groupsFor = person: builtins.filter (group: builtins.elem group person.groups) accessGroups;
  authorizedUsers = lib.filterAttrs (_: person: groupsFor person != [ ]) config.host.sso.users;
  admins =
    if ssoApplication == null || ssoApplication.adminGroup == null then
      { }
    else
      lib.filterAttrs (
        _: person: builtins.elem ssoApplication.adminGroup person.groups
      ) config.host.sso.users;
  containerImage = import ../../_lib/oci-image.nix {
    image = cfg.container;
    inherit pkgs;
  };
  service = config.host.web.services.romm;
  oidcClient = config.host.sso.oidc.clients.romm or null;
  publicUrl = if service.public.url == null then "" else service.public.url;
  storageGroup = if claim == null then null else claim.resolvedResource.sharedGroup;
  basePath = if claim == null then null else "${claim.mountPoint}/${cfg.storage.relativePath}";
  state = {
    inherit (cfg) stateDir;
    webDir = "${cfg.stateDir}/web";
    nginxDir = "${cfg.stateDir}/nginx";
    integrationDir = "${cfg.stateDir}/integration";
    zipCacheModule = "${cfg.stateDir}/integration/utils/zip_cache.py";
    valkeyDir = "${cfg.stateDir}/valkey";
  };
  image = containerImage.ref;
  inherit (containerImage) imageFile;
  uid = if account == null then null else account.uid;
  podmanSocket =
    if uid == null then null else "http+unix:///run/user/${toString uid}/podman/podman.sock";
  commonEnvironment = {
    PATH = "/src/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
    PYTHONDONTWRITEBYTECODE = "1";
    PYTHONUNBUFFERED = "1";
    PYTHONPATH = "/backend";
    ROMM_BASE_URL = publicUrl;
    ROMM_SESSION_SECURE_COOKIE = "true";
    DB_HOST = "localhost";
    DB_USER = cfg.database.name;
    DB_QUERY_JSON = builtins.toJSON {
      unix_socket = "/run/mysqld/mysqld.sock";
    };
    REDIS_HOST = "10.0.2.2";
    REDIS_PORT = toString cfg.cache.port;
    ENABLE_RESCAN_ON_FILESYSTEM_CHANGE = "true";
    LAUNCHBOX_API_ENABLED = "true";
    ENABLE_SCHEDULED_UPDATE_LAUNCHBOX_METADATA = "true";
    HASHEOUS_API_ENABLED = "true";
    DISABLE_USERPASS_LOGIN = "true";
    OIDC_ENABLED = "true";
    OIDC_AUTOLOGIN = "false";
    OIDC_PROVIDER = "SSO";
    OIDC_CLIENT_ID = if oidcClient == null then "" else oidcClient.clientId;
    OIDC_REDIRECT_URI = "${publicUrl}/api/oauth/openid";
    OIDC_SERVER_APPLICATION_URL = if oidcClient == null then "" else oidcClient.issuerUrl;
    OIDC_SERVER_METADATA_URL = if oidcClient == null then "" else oidcClient.discoveryUrl;
    OIDC_CLAIM_ROLES = "romm_roles";
    OIDC_ROLE_ADMIN =
      if ssoApplication == null || ssoApplication.adminGroup == null then
        ""
      else
        ssoApplication.adminGroup;
    OIDC_ROLE_EDITOR =
      if ssoApplication == null || ssoApplication.editorGroup == null then
        ""
      else
        ssoApplication.editorGroup;
    OIDC_ROLE_VIEWER =
      if ssoApplication == null || ssoApplication.viewerGroup == null then
        ""
      else
        ssoApplication.viewerGroup;
    OIDC_USERNAME_ATTRIBUTE = "preferred_username";
  };
  containerMounts =
    if basePath == null then
      [ ]
    else
      [
        {
          source = basePath;
          target = "/romm";
          readOnly = false;
        }
        {
          source = "/run/mysqld";
          target = "/run/mysqld";
          readOnly = true;
        }
        {
          source = state.zipCacheModule;
          target = "/backend/utils/zip_cache.py";
          readOnly = true;
        }
      ];
  registrationReady =
    claim != null
    && storageGroup != null
    && account != null
    && ssoApplication != null
    && ssoApplication.adminGroup != null
    && ssoApplication.editorGroup != null
    && ssoApplication.viewerGroup != null
    && ssoApplication.bootstrapOwner != null
    && cfg.publicHostName != null;
  ready = registrationReady && oidcClient != null;
in
{
  inherit
    accessGroups
    account
    admins
    authorizedUsers
    basePath
    cfg
    claim
    commonEnvironment
    containerMounts
    groupsFor
    image
    imageFile
    oidcClient
    podmanSocket
    publicUrl
    registrationReady
    ready
    service
    ssoApplication
    state
    storageGroup
    uid
    ;
  oidcScopes = config.host.sso.oidc.baseScopes;
}
