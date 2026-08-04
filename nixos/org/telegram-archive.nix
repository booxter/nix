{
  config,
  hostInventory,
  lib,
  orgPkgs,
  pkgs,
  utils,
  ...
}:
let
  serviceName = "telegram-archive";
  serviceUser = serviceName;
  stateDir = "/var/lib/${serviceName}";
  backupPath = "${stateDir}/backups";
  sessionDir = "${stateDir}/session";
  databasePath = "${backupPath}/telegram_backup.db";
  sessionPath = "${sessionDir}/telegram_archive.session";
  viewerPort = 8091;
  oauth2ProxyPort = 4182;
  migrationUnit = "telegram-archive-migrate.service";
  schedulerUnit = "telegram-archive-scheduler.service";
  viewerUnit = "telegram-archive-viewer.service";
  tgService = hostInventory.servicesById.tg;
  externalOrigin = "https://${tgService.id}.${hostInventory.site.lan.domain}";
  serviceTools = orgPkgs.telegram-archive-service-tools;

  secretAttrs = {
    apiId = "telegramArchiveApiId";
    apiHash = "telegramArchiveApiHash";
    phone = "telegramArchivePhone";
    chatIds = "telegramArchiveChatIds";
  };

  commonEnvironment = {
    BACKUP_PATH = backupPath;
    DATABASE_PATH = databasePath;
    SESSION_DIR = sessionDir;
    SESSION_NAME = "telegram_archive";
    VIEWER_TIMEZONE = "America/New_York";
    LOG_LEVEL = "INFO";
  };

  schedulerEnvironment = commonEnvironment // {
    SCHEDULE = "0 */4 * * *";
    DOWNLOAD_MEDIA = "true";
    MAX_MEDIA_SIZE_MB = "100";
    ENABLE_LISTENER = "true";
    LISTEN_NEW_MESSAGES = "true";
    LISTEN_NEW_MESSAGES_MEDIA = "true";
    LISTEN_EDITS = "true";
    LISTEN_DELETIONS = "true";
    DELETION_MODE = "soft";
    LISTEN_CHAT_ACTIONS = "true";
    # SQLite mode delivers browser live-update events to the viewer over its
    # loopback-only internal endpoint.
    VIEWER_HOST = "127.0.0.1";
    VIEWER_PORT = toString viewerPort;
    # Soft deletion only annotates retained rows, so burst protection would
    # make the deletion markers less complete without protecting archive data.
    MASS_OPERATION_THRESHOLD = "1000000";
    SYNC_DELETIONS_EDITS = "false";
  };

  viewerEnvironment = commonEnvironment // {
    AUTH_PROXY_HEADER = "X-User";
    AUTH_PROXY_ADMIN_USERS = "ihar";
    AUTH_PROXY_DEFAULT_ACCESS = "none";
    ALLOW_ANONYMOUS_VIEWER = "false";
    TRUST_PROXY_HEADERS = "true";
    CORS_ORIGINS = externalOrigin;
    SECURE_COOKIES = "true";
    PUSH_NOTIFICATIONS = "basic";
    SHOW_STATS = "true";
  };

  schedulerCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' serviceTools "telegram-archive-scheduler")
    (lib.getExe orgPkgs.telegram-archive)
    "schedule"
  ];
  viewerCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' serviceTools "telegram-archive-viewer")
    "${orgPkgs.telegram-archive}/bin/telegram-archive-viewer"
    "--host"
    "127.0.0.1"
    "--port"
    (toString viewerPort)
    "--proxy-headers"
    "--forwarded-allow-ips"
    "127.0.0.1"
  ];
  authConfig = (pkgs.formats.json { }).generate "telegram-archive-auth.json" {
    executable = lib.getExe orgPkgs.telegram-archive;
    scheduler_unit = schedulerUnit;
    user = serviceUser;
    state_directory = stateDir;
    credentials = {
      api_id = config.sops.secrets.${secretAttrs.apiId}.path;
      api_hash = config.sops.secrets.${secretAttrs.apiHash}.path;
      phone = config.sops.secrets.${secretAttrs.phone}.path;
      chat_ids = config.sops.secrets.${secretAttrs.chatIds}.path;
    };
    environment = schedulerEnvironment;
  };

  commonServiceConfig = {
    User = serviceUser;
    Group = serviceUser;
    StateDirectory = serviceName;
    StateDirectoryMode = "0700";
    WorkingDirectory = stateDir;
    UMask = "0077";
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
    ];
    LockPersonality = true;
  };
in
{
  users.groups.${serviceUser} = { };
  users.users.${serviceUser} = {
    description = "Telegram Archive service user";
    isSystemUser = true;
    group = serviceUser;
  };

  sops.secrets = {
    ${secretAttrs.apiId} = {
      key = "telegramArchive/apiId";
      owner = serviceUser;
      group = serviceUser;
      mode = "0400";
      restartUnits = [ "telegram-archive-scheduler.service" ];
    };
    ${secretAttrs.apiHash} = {
      key = "telegramArchive/apiHash";
      owner = serviceUser;
      group = serviceUser;
      mode = "0400";
      restartUnits = [ "telegram-archive-scheduler.service" ];
    };
    ${secretAttrs.phone} = {
      key = "telegramArchive/phone";
      owner = serviceUser;
      group = serviceUser;
      mode = "0400";
      restartUnits = [ "telegram-archive-scheduler.service" ];
    };
    ${secretAttrs.chatIds} = {
      key = "telegramArchive/chatIds";
      owner = serviceUser;
      group = serviceUser;
      mode = "0400";
      restartUnits = [
        "telegram-archive-scheduler.service"
        "telegram-archive-viewer.service"
      ];
    };
  };

  environment.systemPackages = [ serviceTools ];

  environment.etc."telegram-archive/auth.json" = {
    source = authConfig;
    mode = "0400";
  };

  systemd.services = {
    telegram-archive-migrate = {
      description = "Migrate the Telegram Archive database";
      before = [
        schedulerUnit
        viewerUnit
      ];
      environment = commonEnvironment;
      unitConfig.ConditionPathExists = databasePath;
      serviceConfig = commonServiceConfig // {
        Type = "oneshot";
        ExecStart = "${orgPkgs.telegram-archive}/bin/telegram-archive-migrate";
        RemainAfterExit = true;
      };
    };

    telegram-archive-scheduler = {
      description = "Telegram Archive scheduler and real-time listener";
      wantedBy = [ "multi-user.target" ];
      # Authentication creates this session. Keep first deployment quiet until
      # the operator has completed Telegram's interactive login flow.
      unitConfig.ConditionPathExists = sessionPath;
      wants = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      requires = [ migrationUnit ];
      after = [
        migrationUnit
        "network-online.target"
        "sops-install-secrets.service"
      ];
      environment = schedulerEnvironment;
      serviceConfig = commonServiceConfig // {
        ExecStart = schedulerCommand;
        LoadCredential = [
          "api-id:${config.sops.secrets.${secretAttrs.apiId}.path}"
          "api-hash:${config.sops.secrets.${secretAttrs.apiHash}.path}"
          "phone:${config.sops.secrets.${secretAttrs.phone}.path}"
          "chat-ids:${config.sops.secrets.${secretAttrs.chatIds}.path}"
        ];
        Restart = "always";
        RestartSec = "15s";
      };
    };

    telegram-archive-viewer = {
      description = "Telegram Archive web viewer";
      wantedBy = [ "multi-user.target" ];
      wants = [ "sops-install-secrets.service" ];
      requires = [ migrationUnit ];
      after = [
        migrationUnit
        "sops-install-secrets.service"
      ];
      environment = viewerEnvironment;
      serviceConfig = commonServiceConfig // {
        ExecStart = viewerCommand;
        LoadCredential = [
          "chat-ids:${config.sops.secrets.${secretAttrs.chatIds}.path}"
        ];
        Restart = "always";
        RestartSec = "5s";
      };
    };
  };

  host.internalHttps.services.tg = {
    enable = true;
    upstream = "http://127.0.0.1:${toString viewerPort}";
  };

  host.sso.oauth2ProxyGates.tg = {
    enable = true;
    clientId = "tg";
    httpAddress = "http://127.0.0.1:${toString oauth2ProxyPort}";
    cookieName = "_tg_sso";
    allowedGroups = [ "infra-admins" ];
    groupClaim = "infra_groups";
    inherit externalOrigin;
    whitelistDomains = [ "tg.${hostInventory.site.lan.domain}" ];
    internalHttpsServiceNames = [ "tg" ];
    authRequestHeaders = [
      {
        variableName = "tg_user";
        upstreamHeader = "x_auth_request_preferred_username";
        proxyHeader = "X-User";
      }
    ];
    probeLocationsByName.tg."= /api/health" = {
      proxyPass = "http://127.0.0.1:${toString viewerPort}";
      recommendedProxySettings = true;
      extraConfig = ''
        auth_request off;
      '';
    };
  };
}
