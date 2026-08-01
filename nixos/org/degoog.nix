{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  degoogPackage = (import ../../pkgs pkgs).degoog;
  degoogService = hostInventory.servicesById.goo;
  serviceName = "degoog";
  serviceUser = serviceName;
  stateDir = "/var/lib/${serviceName}";
  runtimeDir = "/run/${serviceName}";
  socketPath = "${runtimeDir}/${serviceName}.sock";
  upstream = "http://unix:${socketPath}";
  oauth2ProxyPort = 4183;
in
{
  sops.secrets."degoog/settings_password" = {
    owner = serviceUser;
    group = serviceUser;
    mode = "0400";
    restartUnits = [ "degoog.service" ];
  };

  sops.templates."degoog.env" = {
    owner = serviceUser;
    group = serviceUser;
    mode = "0400";
    content = ''
      DEGOOG_SETTINGS_PASSWORDS=${config.sops.placeholder."degoog/settings_password"}
    '';
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
      DEGOOG_DATA_DIR = stateDir;
      DEGOOG_DISTRUST_PROXY = "0";
      DEGOOG_DOCKER = "true";
      DEGOOG_PUBLIC_INSTANCE = "false";
      DEGOOG_UNIX_SOCKET = socketPath;
      LOG_LEVEL = "info";
      NO_COLOR = "1";
      TZ = "America/New_York";
    };
    serviceConfig = {
      ExecStart = lib.getExe degoogPackage;
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
    probeLocationsByName.goo."= /readyz" = {
      proxyPass = upstream;
      recommendedProxySettings = true;
      extraConfig = ''
        auth_request off;
      '';
    };
  };
}
