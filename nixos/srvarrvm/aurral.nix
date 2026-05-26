{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  aurralPort = 3001;
  mediaPath = config.host.srvarrPaths.mediaDir;
  aurralStateDir = "${config.host.srvarrPaths.stateDir}/aurral";
  aurralFlowDir = "${mediaPath}/library/flows";
  aurralService = hostInventory.servicesById.aurral;
  aurralUnitDeps = {
    Wants = [ "network-online.target" ];
    After = [ "network-online.target" ];
    RequiresMountsFor = mediaPath;
  };
in
{
  users.groups.aurral = { };
  users.users.aurral = {
    isSystemUser = true;
    group = "aurral";
    extraGroups = [ "media" ];
  };

  systemd.tmpfiles.rules = [
    "d ${aurralStateDir} 0750 aurral aurral - -"
    "z ${aurralStateDir} 0750 aurral aurral - -"
  ];

  systemd.services.aurral = {
    description = "Aurral music discovery and flow download service";
    wantedBy = [ "multi-user.target" ];
    unitConfig = aurralUnitDeps;
    path = [ pkgs.coreutils ];
    environment = {
      AURRAL_DATA_DIR = aurralStateDir;
      DOWNLOAD_FOLDER = aurralFlowDir;
      WEEKLY_FLOW_FOLDER = aurralFlowDir;
      PORT = toString aurralPort;
      # Public access traverses beast nginx first and then the local srvarr
      # nginx proxy in front of the app.
      TRUST_PROXY = "2";
    };
    serviceConfig = {
      ExecStart = lib.getExe pkgs.aurral;
      User = "aurral";
      Group = "aurral";
      WorkingDirectory = aurralStateDir;
      UMask = "0007";
      Restart = "on-failure";
      RestartSec = "5s";
      LimitNOFILE = 65536;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ReadWritePaths = [
        aurralStateDir
        aurralFlowDir
      ];
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

  host.internalHttps.services.aurral = {
    enable = true;
    upstream = "http://127.0.0.1:${toString aurralPort}";
    serverAliases = [ aurralService.publicHost ];
    mtls.enable = true;
  };
}
