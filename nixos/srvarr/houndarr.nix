{
  config,
  lib,
  srvarrPkgs,
  ...
}:
let
  port = 8877;
  stateDir = "${config.host.srvarrPaths.stateDir}/houndarr";
in
{
  users = {
    groups.houndarr = { };
    users.houndarr = {
      description = "Houndarr service user";
      isSystemUser = true;
      group = "houndarr";
    };
  };

  systemd = {
    services.houndarr = {
      description = "Polite Arr search scheduler";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "lidarr.service"
        "radarr.service"
        "sonarr.service"
      ];
      environment = {
        # Uvicorn otherwise trusts nginx's X-Forwarded-For and rewrites the
        # ASGI peer to the browser address. Houndarr's proxy-auth trust check
        # must instead see the actual loopback peer; it handles forwarded
        # client addresses itself where needed for rate limiting.
        FORWARDED_ALLOW_IPS = "";
        HOUNDARR_AUTH_MODE = "proxy";
        HOUNDARR_AUTH_PROXY_HEADER = "X-User";
        HOUNDARR_COOKIE_SAMESITE = "lax";
        HOUNDARR_DATA_DIR = stateDir;
        HOUNDARR_DEV = "false";
        HOUNDARR_HOST = "127.0.0.1";
        HOUNDARR_LOG_LEVEL = "info";
        HOUNDARR_PORT = toString port;
        HOUNDARR_SECURE_COOKIES = "true";
        HOUNDARR_TRUSTED_PROXIES = "127.0.0.1/32";
      };
      serviceConfig = {
        ExecStart = lib.getExe srvarrPkgs.houndarr;
        Restart = "on-failure";
        RestartSec = "5s";
        User = "houndarr";
        Group = "houndarr";
        UMask = "0077";

        CapabilityBoundingSet = "";
        DevicePolicy = "closed";
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        ReadWritePaths = [ stateDir ];
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
      unitConfig.RequiresMountsFor = stateDir;
    };

    tmpfiles.rules = [
      "d ${stateDir} 0700 houndarr houndarr -"
    ];
  };

  host.internalHttps.services.houndarr = {
    enable = true;
    upstream = "http://127.0.0.1:${toString port}";
  };
}
