{
  config,
  lib,
  pkgs,
  storageModel,
  storageIdentities ? import ../storage/identities.nix,
}:
let
  cfg = config.host.romm;
  port = 5081;
  databaseName = "romm";
  cachePort = 6380;
  toolsPackage = pkgs.callPackage ./package { };
  user = "romm";
  storageClaim = "media";
  storageRelativePath = "romm";
  claim = storageModel.localClaims.${storageClaim} or null;
  identity = storageIdentities.users.${user} or null;
  ssoApplication = config.host.sso.applications.romm or null;
  accessGroups = if ssoApplication == null then [ ] else builtins.attrValues ssoApplication.roles;
  groupsFor = person: builtins.filter (group: builtins.elem group person.groups) accessGroups;
  authorizedUsers = lib.filterAttrs (_: person: groupsFor person != [ ]) config.host.sso.users;
  admins =
    if ssoApplication == null then
      { }
    else
      lib.filterAttrs (
        _: person: builtins.elem ssoApplication.roles.admin person.groups
      ) config.host.sso.users;
  service = config.host.web.services.romm;
  oidcClient = config.host.sso.oidc.clients.romm or null;
  publicUrl = service.public.url;
  storageGroup =
    if claim == null || claim.resolvedResource.directoryDefaults.group == "root" then
      null
    else
      claim.resolvedResource.directoryDefaults.group;
  basePath = if claim == null then null else "${claim.mountPoint}/${storageRelativePath}";
  state = {
    inherit (cfg) stateDir;
    valkeyDir = "${cfg.stateDir}/valkey";
  };
  uid = if identity == null then null else identity.uid;
  commonEnvironment = {
    PYTHONDONTWRITEBYTECODE = "1";
    PYTHONUNBUFFERED = "1";
    ROMM_BASE_URL = publicUrl;
    ROMM_SESSION_SECURE_COOKIE = "true";
    DB_HOST = "localhost";
    DB_USER = databaseName;
    DB_QUERY_JSON = builtins.toJSON {
      unix_socket = "/run/mysqld/mysqld.sock";
    };
    ROMM_DB_DRIVER = "mariadb";
    WEB_SERVER_CONCURRENCY = "1";
    ENABLE_RESCAN_ON_FILESYSTEM_CHANGE = "true";
    LAUNCHBOX_API_ENABLED = "true";
    ENABLE_SCHEDULED_UPDATE_LAUNCHBOX_METADATA = "true";
    HASHEOUS_API_ENABLED = "true";
    DISABLE_USERPASS_LOGIN = "true";
    OIDC_ENABLED = "true";
    OIDC_AUTOLOGIN = "false";
    OIDC_PROVIDER = "SSO";
    OIDC_CLIENT_ID = oidcClient.clientId;
    OIDC_REDIRECT_URI = "${publicUrl}/api/oauth/openid";
    OIDC_SERVER_APPLICATION_URL = oidcClient.issuerUrl;
    OIDC_SERVER_METADATA_URL = oidcClient.discoveryUrl;
    OIDC_CLAIM_ROLES = "romm_roles";
    OIDC_ROLE_ADMIN = ssoApplication.roles.admin;
    OIDC_ROLE_EDITOR = ssoApplication.roles.editor;
    OIDC_ROLE_VIEWER = ssoApplication.roles.viewer;
    OIDC_USERNAME_ATTRIBUTE = "preferred_username";
  };
  registrationReady =
    claim != null
    && storageGroup != null
    && identity != null
    && ssoApplication != null
    && ssoApplication.roles ? admin
    && ssoApplication.roles ? editor
    && ssoApplication.roles ? viewer
    && ssoApplication.bootstrapOwner != null;
  ready = registrationReady && oidcClient != null;
  units = {
    runtime = [
      "romm.service"
      "romm-scheduler.service"
      "romm-worker.service"
      "romm-watcher.service"
    ];
    tmpfiles = [
      "systemd-tmpfiles-setup.service"
      "systemd-tmpfiles-resetup.service"
    ];
    setupBefore = [
      "mysql.service"
      "romm-db-init.service"
      "romm-valkey.service"
      "sops-install-secrets.service"
      "romm-backup.service"
    ];
  };
in
{
  inherit
    accessGroups
    admins
    authorizedUsers
    basePath
    cachePort
    cfg
    claim
    commonEnvironment
    databaseName
    groupsFor
    identity
    oidcClient
    port
    publicUrl
    registrationReady
    ready
    service
    ssoApplication
    state
    storageGroup
    storageClaim
    storageRelativePath
    toolsPackage
    uid
    units
    user
    ;
  oidcScopes = config.host.sso.oidc.baseScopes;
}
