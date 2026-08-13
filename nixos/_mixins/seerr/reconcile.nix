{
  config,
  lib,
  outputs,
  pkgs,
  utils,
  ...
}:
let
  model = import ./model.nix { inherit config lib outputs; };
  inherit (model) cfg;
  credentialName = kind: name: "${kind}-${name}-api";
  servarrConfig =
    kind: instance:
    {
      api = instance.api.service.upstream;
      availability_sync = instance.integration.availabilitySync;
      credential = {
        name = credentialName kind instance.name;
        inherit (instance.api.authentication.apiKey) field format;
      };
      default = instance.integration.default;
      display_name = instance.integration.displayName;
      library_path = instance.media.path;
      profile = instance.integration.profile;
      search_requests = instance.integration.searchRequests;
      tag_requests = instance.integration.tagRequests;
    }
    // lib.optionalAttrs (kind == "radarr") {
      minimum_availability = instance.integration.minimumAvailability;
    }
    // lib.optionalAttrs (kind == "sonarr") {
      monitor_new_items = instance.integration.monitorNewItems;
      season_folders = instance.integration.seasonFolders;
    };
  telegram = cfg.notifications.telegram;
  telegramCredentialNames = {
    botApi = "telegram-bot-api";
    botUsername = "telegram-bot-username";
    chatId = "telegram-chat-id";
    messageThreadId = "telegram-message-thread-id";
  };
  configuration = pkgs.writeText "seerr-reconcile.json" (
    builtins.toJSON {
      main = {
        default_permissions = cfg.requestPolicy.defaultPermissions;
        local_login = cfg.authentication.local.enable;
        media_server_login = cfg.integrations.jellyfin.authentication.enable;
        partial_requests = cfg.requestPolicy.partialRequests;
        special_episodes = cfg.requestPolicy.specialEpisodes;
      };
      jellyfin = {
        url = model.jellyfin.publicUrl;
        api_key_credential = "jellyfin-api-key";
        libraries = map (name: model.jellyfin.libraries.${name}.name) cfg.integrations.jellyfin.libraries;
      };
      metadata = {
        inherit (cfg.metadata) anime series;
      };
      radarr = map (servarrConfig "radarr") (builtins.attrValues model.radarr);
      sonarr = map (servarrConfig "sonarr") (builtins.attrValues model.sonarr);
      telegram =
        if telegram.enable then
          {
            bot_api_credential = telegramCredentialNames.botApi;
            bot_username_credential = telegramCredentialNames.botUsername;
            chat_id_credential = telegramCredentialNames.chatId;
            embed_poster = telegram.embedPoster;
            message_thread_credential =
              if telegram.secrets.messageThreadId == null then "" else telegramCredentialNames.messageThreadId;
            send_silently = telegram.sendSilently;
            events = telegram.events;
          }
        else
          null;
    }
  );
  servarrInstances = builtins.attrValues model.radarr ++ builtins.attrValues model.sonarr;
  apiUnits = lib.unique (
    builtins.filter (unit: unit != null) (map (instance: instance.api.localUnit) servarrInstances)
  );
  servarrCredentials = map (
    instance:
    "${credentialName instance.kind instance.name}:${instance.api.authentication.apiKey.source}"
  ) servarrInstances;
  telegramCredentials = lib.optionals telegram.enable (
    [
      "${telegramCredentialNames.botApi}:${config.sops.secrets.${telegram.secrets.botApi}.path}"
      "${telegramCredentialNames.botUsername}:${config.sops.secrets.${telegram.secrets.botUsername}.path}"
      "${telegramCredentialNames.chatId}:${config.sops.secrets.${telegram.secrets.chatId}.path}"
    ]
    ++
      lib.optional (telegram.secrets.messageThreadId != null)
        "${telegramCredentialNames.messageThreadId}:${
          config.sops.secrets.${telegram.secrets.messageThreadId}.path
        }"
  );
  command = utils.escapeSystemdExecArgs [
    (lib.getExe cfg.reconcilePackage)
    "--api-key-credential"
    "seerr-api-key"
    "--config"
    configuration
    "--url"
    "http://127.0.0.1:${toString config.services.seerr.port}"
    "--timeout"
    "2m"
  ];
in
{
  config = lib.mkIf cfg.enable {
    sops.secrets = {
      ${cfg.apiKeySecret}.restartUnits = [
        "seerr.service"
        "seerr-reconcile.service"
      ];
      ${cfg.integrations.jellyfin.apiKeySecret}.restartUnits = [ "seerr-reconcile.service" ];
    }
    // lib.optionalAttrs telegram.enable {
      ${telegram.secrets.botApi}.restartUnits = [ "seerr-reconcile.service" ];
      ${telegram.secrets.botUsername}.restartUnits = [ "seerr-reconcile.service" ];
      ${telegram.secrets.chatId}.restartUnits = [ "seerr-reconcile.service" ];
    }
    // lib.optionalAttrs (telegram.enable && telegram.secrets.messageThreadId != null) {
      ${telegram.secrets.messageThreadId}.restartUnits = [ "seerr-reconcile.service" ];
    };

    sops.templates."seerr-environment" = {
      content = ''
        API_KEY=${config.sops.placeholder.${cfg.apiKeySecret}}
      '';
      owner = cfg.user;
      group = cfg.group;
      mode = "0400";
      restartUnits = [ "seerr.service" ];
    };

    systemd.services.seerr-reconcile = {
      description = "Reconcile declarative Seerr settings";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "seerr.service"
        "sops-install-secrets.service"
      ]
      ++ apiUnits;
      after = [
        "seerr.service"
        "sops-install-secrets.service"
      ]
      ++ apiUnits;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = command;
        LoadCredential = [
          "seerr-api-key:${config.sops.secrets.${cfg.apiKeySecret}.path}"
          "jellyfin-api-key:${config.sops.secrets.${cfg.integrations.jellyfin.apiKeySecret}.path}"
        ]
        ++ servarrCredentials
        ++ telegramCredentials;
        Restart = "on-failure";
        RestartSec = "5s";
        User = cfg.user;
        Group = cfg.group;
        UMask = "0077";
        CapabilityBoundingSet = "";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
      };
    };

    systemd.paths = lib.listToAttrs (
      map (instance: {
        name = "seerr-${instance.kind}-${instance.name}-api-credential";
        value = {
          wantedBy = [ "paths.target" ];
          pathConfig = {
            PathChanged = instance.api.authentication.apiKey.source;
            Unit = "seerr-reconcile.service";
          };
        };
      }) servarrInstances
    );
  };
}
