{
  config,
  hostInventory,
  lib,
  orgPkgs,
  pkgs,
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
  viewerPort = 8080;
  oauth2ProxyPort = 4182;
  tgService = hostInventory.servicesById.tg;
  externalOrigin = "https://${tgService.id}.${hostInventory.site.lan.domain}";

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

  authEnvironmentArgs = lib.concatMapStringsSep " " (
    name: lib.escapeShellArg "--setenv=${name}=${schedulerEnvironment.${name}}"
  ) (builtins.attrNames schedulerEnvironment);

  chatIdsFromCredential = ''
    credentials_dir="''${CREDENTIALS_DIRECTORY:?systemd credentials are required}"
    chat_ids="$(${lib.getExe pkgs.jq} -er '
      if type == "array" and length > 0 and all(.[]; type == "number" and floor == .)
      then map(tostring) | join(",")
      else error("chat-ids must be a non-empty JSON array of integer Telegram chat IDs")
      end
    ' "$credentials_dir/chat-ids")"
  '';

  schedulerWrapper = pkgs.writeShellApplication {
    name = "telegram-archive-scheduler-wrapper";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      set -euo pipefail

      ${chatIdsFromCredential}

      read_secret() {
        tr -d '\r\n' < "$credentials_dir/$1"
      }

      TELEGRAM_API_ID="$(read_secret api-id)"
      TELEGRAM_API_HASH="$(read_secret api-hash)"
      TELEGRAM_PHONE="$(read_secret phone)"
      export TELEGRAM_API_ID TELEGRAM_API_HASH TELEGRAM_PHONE
      export CHAT_IDS="$chat_ids"
      export DISPLAY_CHAT_IDS="$chat_ids"

      exec ${lib.getExe orgPkgs.telegram-archive} "$@"
    '';
  };

  viewerWrapper = pkgs.writeShellApplication {
    name = "telegram-archive-viewer-wrapper";
    text = ''
      set -euo pipefail

      ${chatIdsFromCredential}
      export DISPLAY_CHAT_IDS="$chat_ids"

      exec ${orgPkgs.telegram-archive}/bin/telegram-archive-viewer \
        --host 127.0.0.1 \
        --port ${toString viewerPort} \
        --proxy-headers \
        --forwarded-allow-ips 127.0.0.1
    '';
  };

  telegramArchiveAuth = pkgs.writeShellApplication {
    name = "telegram-archive-auth";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      set -euo pipefail

      if systemctl is-active --quiet telegram-archive-scheduler.service; then
        echo "telegram-archive-scheduler.service is running; stop it before authenticating" >&2
        exit 1
      fi

      exec systemd-run \
        --collect \
        --wait \
        --pty \
        --unit=telegram-archive-auth \
        --property=User=${serviceUser} \
        --property=Group=${serviceUser} \
        --property=StateDirectory=${serviceName} \
        --property=StateDirectoryMode=0700 \
        --property=WorkingDirectory=${stateDir} \
        --property=UMask=0077 \
        --property=LoadCredential=api-id:${config.sops.secrets.${secretAttrs.apiId}.path} \
        --property=LoadCredential=api-hash:${config.sops.secrets.${secretAttrs.apiHash}.path} \
        --property=LoadCredential=phone:${config.sops.secrets.${secretAttrs.phone}.path} \
        --property=LoadCredential=chat-ids:${config.sops.secrets.${secretAttrs.chatIds}.path} \
        ${authEnvironmentArgs} \
        ${schedulerWrapper}/bin/telegram-archive-scheduler-wrapper auth
    '';
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

  environment.systemPackages = [ telegramArchiveAuth ];

  systemd.services = {
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
      after = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      environment = schedulerEnvironment;
      serviceConfig = commonServiceConfig // {
        ExecStart = "${schedulerWrapper}/bin/telegram-archive-scheduler-wrapper schedule";
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
      after = [ "sops-install-secrets.service" ];
      environment = viewerEnvironment;
      serviceConfig = commonServiceConfig // {
        ExecStart = "${viewerWrapper}/bin/telegram-archive-viewer-wrapper";
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
