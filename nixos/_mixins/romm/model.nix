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
  containerImage = import ../../_lib/oci-image.nix {
    image = cfg.container;
    inherit pkgs;
  };
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
    webDir = "${cfg.stateDir}/web";
    nginxDir = "${cfg.stateDir}/nginx";
    integrationDir = "${cfg.stateDir}/integration";
    zipCacheModule = "${cfg.stateDir}/integration/utils/zip_cache.py";
    valkeyDir = "${cfg.stateDir}/valkey";
  };
  image = containerImage.ref;
  inherit (containerImage) imageFile;
  uid = if identity == null then null else identity.uid;
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
    DB_USER = databaseName;
    DB_QUERY_JSON = builtins.toJSON {
      unix_socket = "/run/mysqld/mysqld.sock";
    };
    REDIS_HOST = "10.0.2.2";
    REDIS_PORT = toString cachePort;
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
    && identity != null
    && ssoApplication != null
    && ssoApplication.roles ? admin
    && ssoApplication.roles ? editor
    && ssoApplication.roles ? viewer
    && ssoApplication.bootstrapOwner != null;
  ready = registrationReady && oidcClient != null;
  units = {
    containers = [
      "podman-romm-api.service"
      "podman-romm-scheduler.service"
      "podman-romm-worker.service"
      "podman-romm-watcher.service"
    ];
    user = [
      "user-runtime-dir@${toString uid}.service"
      "user@${toString uid}.service"
    ];
    tmpfiles = [
      "systemd-tmpfiles-setup.service"
      "systemd-tmpfiles-resetup.service"
    ];
    setupBefore = [
      "romm-web-assets.service"
      "mysql.service"
      "romm-db-init.service"
      "romm-valkey.service"
      "sops-install-secrets.service"
      "romm-backup.service"
    ];
  };
  runtimeEnvironment = {
    HOME = cfg.stateDir;
    XDG_RUNTIME_DIR = "/run/user/${toString uid}";
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
    containerMounts
    databaseName
    groupsFor
    image
    imageFile
    identity
    oidcClient
    port
    podmanSocket
    publicUrl
    registrationReady
    runtimeEnvironment
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
