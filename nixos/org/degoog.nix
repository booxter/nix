{
  config,
  hostInventory,
  lib,
  orgPkgs,
  pkgs,
  ...
}:
let
  degoogPackage = orgPkgs.degoog;
  trustedHeaderSettingsAuth = orgPkgs.degoog-trusted-header-settings-auth;
  degoogExtensions = orgPkgs.degoog-official-extensions.override {
    # Full catalog: https://degoog-org.github.io/community-extensions/
    extensions = [
      "autocomplete/brave"
      "engines/brave"
      "engines/brave-images"
      "engines/brave-news"
      "engines/devinside-devinside-degoog-osmapp-maps"
      "engines/duckduckgo"
      "engines/duckduckgo-images"
      "engines/duckduckgo-news"
      "engines/google-cse"
      "engines/hacker-news"
      "engines/internet-archive"
      "engines/pross-degoog-stackexchange-engine-stackexchange"
      "engines/reddit"
      "engines/wikipedia"
      "plugins/ddg-bang"
      "plugins/define"
      "plugins/devinside-devinside-degoog-local-history"
      "plugins/georgvwt-georgvwt-degoog-stuff-osm-slot"
      "plugins/georgvwt-georgvwt-degoog-stuff-reddit-slot"
      "plugins/github-slot"
      "plugins/highlight-terms"
      "plugins/jellyfin"
      "plugins/math-slot"
      "plugins/romm"
      # Stocks uses a slot position introduced in Degoog 0.24.0. Its package
      # patches that position for 0.23.x and asserts when the patch is stale.
      "plugins/sopat712-degoog-toolkit-stocks"
      "plugins/time"
      "plugins/tmdb-slot"
      "plugins/trusted-header-settings-auth"
      "plugins/weather"
      "themes/georgvwt-georgvwt-degoog-stuff-gruvbox-theme"
    ];
    extraExtensionSources = {
      "engines/devinside-devinside-degoog-osmapp-maps" =
        "${orgPkgs.degoog-devinside-extensions}/engines/osmapp-maps";
      "engines/pross-degoog-stackexchange-engine-stackexchange" = orgPkgs.degoog-stackexchange-engine;
      "plugins/devinside-devinside-degoog-local-history" =
        "${orgPkgs.degoog-devinside-extensions}/plugins/local-history";
      "plugins/georgvwt-georgvwt-degoog-stuff-osm-slot" =
        "${orgPkgs.degoog-georgvwt-extensions}/plugins/osm-slot";
      "plugins/georgvwt-georgvwt-degoog-stuff-reddit-slot" =
        "${orgPkgs.degoog-georgvwt-extensions}/plugins/reddit-slot";
      "plugins/sopat712-degoog-toolkit-stocks" = "${orgPkgs.degoog-toolkit-extensions}/plugins/stocks";
      "plugins/trusted-header-settings-auth" = trustedHeaderSettingsAuth;
      "themes/georgvwt-georgvwt-degoog-stuff-gruvbox-theme" =
        "${orgPkgs.degoog-georgvwt-extensions}/themes/gruvbox";
    };
  };
  degoogService = hostInventory.servicesById.goo;
  jellyfinService = hostInventory.servicesById.jellyfin;
  rommService = hostInventory.servicesById.romm;
  serviceName = "degoog";
  serviceUser = serviceName;
  stateDir = "/var/lib/${serviceName}";
  runtimeDir = "/run/${serviceName}";
  socketPath = "${runtimeDir}/${serviceName}.sock";
  pluginSettingsFile = "${stateDir}/plugin-settings.json";
  upstream = "http://unix:${socketPath}";
  oauth2ProxyPort = 4183;
  secretNames = [
    "github_api_token"
    "jellyfin_api_key"
    "romm_api_token"
    "settings_password"
    "stackexchange_api_key"
    "tmdb_api_key"
  ];
  mergePluginSettings = pkgs.writeShellApplication {
    name = "degoog-merge-plugin-settings";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      target=${lib.escapeShellArg pluginSettingsFile}
      desired=${lib.escapeShellArg config.sops.templates."degoog-plugin-settings.json".path}
      temporary="$(mktemp "$target.XXXXXX")"
      trap 'rm -f "$temporary"' EXIT

      if [[ -f "$target" ]]; then
        jq --slurp '.[0] * .[1]' "$target" "$desired" > "$temporary"
      else
        jq '.' "$desired" > "$temporary"
      fi

      chmod 0600 "$temporary"
      mv -f "$temporary" "$target"
      trap - EXIT
    '';
  };
in
{
  sops.secrets = lib.genAttrs (map (name: "degoog/${name}") secretNames) (_: {
    owner = serviceUser;
    group = serviceUser;
    mode = "0400";
    restartUnits = [ "degoog.service" ];
  });

  sops.templates."degoog.env" = {
    owner = serviceUser;
    group = serviceUser;
    mode = "0400";
    content = ''
      DEGOOG_SETTINGS_PASSWORDS=${config.sops.placeholder."degoog/settings_password"}
    '';
    restartUnits = [ "degoog.service" ];
  };

  sops.templates."degoog-plugin-settings.json" = {
    owner = serviceUser;
    group = serviceUser;
    mode = "0400";
    content = builtins.toJSON {
      degoog-org-official-extensions-github-slot.apiToken =
        config.sops.placeholder."degoog/github_api_token";
      degoog-org-official-extensions-jellyfin-command = {
        apiKey = config.sops.placeholder."degoog/jellyfin_api_key";
        headerName = "X-Emby-Token";
        url = jellyfinService.url;
      };
      degoog-org-official-extensions-reddit-engine.includeNsfw = "true";
      degoog-org-official-extensions-romm-command = {
        apiToken = config.sops.placeholder."degoog/romm_api_token";
        url = rommService.url;
      };
      degoog-org-official-extensions-tmdb-slot.apiKey = config.sops.placeholder."degoog/tmdb_api_key";
      georgvwt-georgvwt-degoog-stuff-reddit-slot.filterNsfw = false;
      middleware.settingsGate = "plugin:trusted-header-settings-auth-middleware";
      pross-degoog-stackexchange-engine-stackexchange-engine.apiKey =
        config.sops.placeholder."degoog/stackexchange_api_key";
      theme.active = "georgvwt-georgvwt-degoog-stuff-gruvbox-theme";
      trusted-header-settings-auth-middleware.allowedUsers = "ihar";
    };
    restartUnits = [ "degoog.service" ];
  };

  users.groups.${serviceUser} = { };
  users.users.${serviceUser} = {
    isSystemUser = true;
    group = serviceUser;
    home = stateDir;
  };

  systemd.tmpfiles.rules = [
    "d ${runtimeDir} 2750 ${serviceUser} ${config.services.nginx.group} - -"
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
      TZ = "America/New_York";
    };
    serviceConfig = {
      ExecStart = lib.getExe degoogPackage;
      ExecStartPre = [
        "${pkgs.coreutils}/bin/rm -f ${socketPath}"
        (lib.getExe mergePluginSettings)
      ];
      EnvironmentFile = config.sops.templates."degoog.env".path;
      User = serviceUser;
      Group = serviceUser;
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

  host.internalHttps.services.goo = {
    enable = true;
    inherit upstream;
    publicAliases = [ degoogService.publicHost ];
    mtls.enable = true;
  };

  host.sso.oauth2ProxyGates.goo = {
    enable = true;
    authFailureMode = "navigation-aware";
    clientId = "goo";
    httpAddress = "http://127.0.0.1:${toString oauth2ProxyPort}";
    cookieName = "_goo_sso";
    allowedGroups = [ "ai-users" ];
    groupClaim = "ai_groups";
    externalOrigin = degoogService.url;
    whitelistDomains = [ degoogService.publicHost ];
    internalHttpsServiceNames = [ "goo" ];
    signInLocationName = "@goo_oauth2_proxy_sign_in";
    authCookieVariableName = "goo_auth_cookie";
    authRequestHeaders = [
      {
        variableName = "goo_user";
        upstreamHeader = "x_auth_request_preferred_username";
        proxyHeader = "X-User";
      }
    ];
    probeLocationsByName.goo."= /readyz" = {
      proxyPass = upstream;
      recommendedProxySettings = true;
      extraConfig = ''
        auth_request off;
      '';
    };
  };
}
