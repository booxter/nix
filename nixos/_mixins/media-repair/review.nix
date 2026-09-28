{
  config,
  lib,
  ...
}:
let
  cfg = config.host.mediaRepair.review;
  serviceName = "media-repair-review";
  lidarrController = "lidarr-repair-controller";
  radarrController = "radarr-repair-controller";
  lidarrDirectory = "${cfg.stateDirectory}/lidarr";
  radarrDirectory = "${cfg.stateDirectory}/radarr";
  lidarrRequests = "${cfg.requestStateDirectory}/lidarr";
  radarrRequests = "${cfg.requestStateDirectory}/radarr";
  command = lib.escapeShellArgs [
    (lib.getExe cfg.package)
    "--listen"
    "127.0.0.1:${toString cfg.port}"
    "--lidarr-snapshot"
    lidarrDirectory
    "--radarr-snapshot"
    radarrDirectory
    "--lidarr-requests"
    lidarrRequests
    "--radarr-requests"
    radarrRequests
    "--lidarr-url"
    "https://lidarr.${config.host.network.lanDomain}/activity/queue"
    "--radarr-url"
    "https://radarr.${config.host.network.lanDomain}/activity/queue"
    "--public-url"
    "https://repairr.${config.host.network.lanDomain}"
  ];
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.host.lidarr != null && config.host.lidarr.repair.controller.enable;
        message = "The repair review inbox requires the Lidarr repair controller.";
      }
      {
        assertion = config.host.radarr != null && config.host.radarr.repair.controller.enable;
        message = "The repair review inbox requires the Radarr repair controller.";
      }
    ];

    users.groups.${cfg.writerGroup} = { };
    users.users.${serviceName} = {
      isSystemUser = true;
      group = cfg.writerGroup;
      home = "/var/empty";
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDirectory} 0750 ${serviceName} ${cfg.writerGroup} - -"
      "d ${lidarrDirectory} 2750 ${lidarrController} ${cfg.writerGroup} - -"
      "d ${radarrDirectory} 2750 ${radarrController} ${cfg.writerGroup} - -"
      "d ${cfg.requestStateDirectory} 0750 ${serviceName} ${cfg.writerGroup} - -"
      "d ${lidarrRequests} 2750 ${serviceName} ${lidarrController} - -"
      "d ${radarrRequests} 2750 ${serviceName} ${radarrController} - -"
    ];

    systemd.services.${serviceName} = {
      description = "Servarr repair review and reconsideration inbox";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = command;
        User = serviceName;
        Group = cfg.writerGroup;
        Restart = "on-failure";
        RestartSec = "5s";
        UMask = "0027";
        AmbientCapabilities = "";
        CapabilityBoundingSet = "";
        IPAddressAllow = [ "localhost" ];
        IPAddressDeny = "any";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
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
        ProcSubset = "pid";
        ReadOnlyPaths = [ cfg.stateDirectory ];
        ReadWritePaths = [ cfg.requestStateDirectory ];
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
      };
    };

    host.web.services.repairr = {
      upstream = "http://127.0.0.1:${toString cfg.port}";
      auth.policy = "media-admin";
    };
  };
}
