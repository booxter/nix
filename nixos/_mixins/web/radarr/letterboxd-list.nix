{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.radarr.letterboxdList;
  hostname = config.networking.hostName;
  service = hostInventory.servicesById."letterboxd-list-radarr";
  instance = service.instances.${hostname} or { };
  requiredServices = instance.requiresLocalServices or [ ];
  nonLocalRequiredServices = builtins.filter (
    name:
    !builtins.hasAttr name hostInventory.servicesById
    || hostInventory.servicesById.${name}.owner != hostname
  ) requiredServices;
  port = 5000;
  redisPort = 6381;
  redisService = "redis-letterboxd-list-radarr.service";
  serviceDeps = [
    "network-online.target"
    redisService
  ];
in
{
  options = {
    host.letterboxdListRadarr.enable = lib.mkOption {
      type = lib.types.bool;
      default = service.owner == hostname;
      readOnly = true;
      internal = true;
      description = "Whether inventory assigns the Letterboxd Radarr bridge to this host.";
    };

    services.radarr.letterboxdList.package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./packages/letterboxd-list-radarr { };
      description = "Package providing the Letterboxd Radarr bridge.";
    };
  };

  config = lib.mkIf config.host.letterboxdListRadarr.enable {
    assertions = [
      {
        assertion = config.services.radarr.enable;
        message = "The Letterboxd Radarr bridge requires Radarr on the same host.";
      }
      {
        assertion = requiredServices == [ "radarr" ];
        message = "The Letterboxd Radarr inventory instance must require local Radarr.";
      }
      {
        assertion = nonLocalRequiredServices == [ ];
        message = "The Letterboxd Radarr bridge must be colocated with Radarr.";
      }
    ];

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
      wants = serviceDeps;
      after = serviceDeps;
      environment = {
        LOG_LEVEL = "info";
        PORT = toString port;
        REDIS_URL = "redis://127.0.0.1:${toString redisPort}/0";
      };
      serviceConfig = {
        ExecStart = lib.getExe cfg.package;
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

    host.internalService.services.letterboxd-list-radarr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString port}";
    };
  };
}
