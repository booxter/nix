{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.radarr;
  package = pkgs.callPackage ./pkgs/letterboxd-list-radarr { };
  port = 5000;
  redisPort = 6381;
  redisService = "redis-letterboxd-list-radarr.service";
in
{
  config = lib.mkIf (cfg != null) {
    services.redis.servers.letterboxd-list-radarr = {
      enable = true;
      bind = "127.0.0.1";
      port = redisPort;
      openFirewall = false;
      save = [ ];
      appendOnly = false;
      settings = {
        maxmemory = "256mb";
        maxmemory-policy = "allkeys-lfu";
      };
    };

    systemd.services.letterboxd-list-radarr = {
      description = "Letterboxd list to Radarr JSON bridge";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      requires = [ redisService ];
      after = [
        "network-online.target"
        redisService
      ];
      environment = {
        LOG_LEVEL = "info";
        PORT = toString port;
        REDIS_URL = "redis://127.0.0.1:${toString redisPort}/0";
      };
      serviceConfig = {
        ExecStart = lib.getExe package;
        DynamicUser = true;
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectHostname = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        LockPersonality = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        RemoveIPC = true;
      };
    };

    host.web.services.letterboxd-list-radarr = {
      upstream = "http://127.0.0.1:${toString port}";
      health.frontend = { };
      displayName = "Letterboxd Radarr";
    };
  };
}
