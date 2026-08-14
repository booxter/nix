{
  config,
  degoogModel,
  lib,
  pkgs,
  utils,
  ...
}:
let
  inherit (degoogModel)
    cfg
    extensionNames
    packages
    selectedRegistrations
    ;
  serviceName = "degoog";
  stateDir = "/var/lib/${serviceName}";
  runtimeDir = "/run/${serviceName}";
  socketPath = "${runtimeDir}/${serviceName}.sock";
  pluginSettingsFile = "${stateDir}/plugin-settings.json";
  degoogExtensions = packages.officialExtensions.override {
    extensions = extensionNames;
    extraExtensionSources = lib.listToAttrs (
      lib.filter (entry: entry.value != null) (
        lib.imap0 (index: name: {
          inherit name;
          value = (builtins.elemAt selectedRegistrations index).source;
        }) extensionNames
      )
    );
  };
  mergePluginSettingsCommand = utils.escapeSystemdExecArgs [
    (lib.getExe packages.settings)
    "--target"
    pluginSettingsFile
    "--desired"
    config.sops.templates."degoog-plugin-settings.json".path
  ];
in
{
  config = lib.mkIf cfg.enable {
    users.groups.${serviceName} = { };
    users.users.${serviceName} = {
      isSystemUser = true;
      group = serviceName;
      home = stateDir;
    };

    systemd.tmpfiles.rules = [
      "d ${runtimeDir} 2750 ${serviceName} ${config.services.nginx.group} - -"
    ];

    systemd.services.degoog = {
      description = "Degoog search aggregator";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      after = [
        "network-online.target"
        "sops-install-secrets.service"
        "systemd-tmpfiles-setup.service"
      ];
      environment = {
        DEGOOG_AUTOCOMPLETE_DIR = "${degoogExtensions}/autocomplete";
        DEGOOG_DATA_DIR = stateDir;
        DEGOOG_DISTRUST_PROXY = "0";
        DEGOOG_DOCKER = "true";
        DEGOOG_ENGINES_DIR = "${degoogExtensions}/engines";
        DEGOOG_PLUGINS_DIR = "${degoogExtensions}/plugins";
        DEGOOG_PLUGIN_SETTINGS_FILE = pluginSettingsFile;
        DEGOOG_PUBLIC_INSTANCE = "false";
        DEGOOG_SHORTCUTS_DIR = "${degoogExtensions}/shortcuts";
        DEGOOG_THEMES_DIR = "${degoogExtensions}/themes";
        DEGOOG_TRANSPORTS_DIR = "${degoogExtensions}/transports";
        DEGOOG_UNIX_SOCKET = socketPath;
        LOG_LEVEL = "info";
        NO_COLOR = "1";
        TZ = config.host.site.timeZone;
      };
      serviceConfig = {
        ExecStart = lib.getExe packages.degoog;
        ExecStartPre = [
          "${pkgs.coreutils}/bin/rm -f ${socketPath}"
          mergePluginSettingsCommand
        ];
        EnvironmentFile = config.sops.templates."degoog.env".path;
        User = serviceName;
        Group = serviceName;
        StateDirectory = serviceName;
        StateDirectoryMode = "0750";
        UMask = "0007";
        Restart = "always";
        RestartSec = "2s";
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
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
      };
    };
  };
}
