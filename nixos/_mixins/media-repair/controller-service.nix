{
  applicationService,
  command,
  credentials,
  description,
  interval,
  planner,
  rootPaths,
  serviceName,
  timerDescription,
  timeoutStopSec,
  worker,
  extraRequiredUnits ? [ ],
  readWritePaths ? [ ],
  wantedUnits ? [ ],
}:
let
  requiredUnits = [
    "media-repair-planner.socket"
    "media-repair-worker.service"
    applicationService
    "sops-install-secrets.service"
  ]
  ++ extraRequiredUnits;
in
{
  users.groups.${serviceName} = { };
  users.users.${serviceName} = {
    isSystemUser = true;
    group = serviceName;
    home = "/var/empty";
  };

  systemd.services.${serviceName} = {
    inherit description;
    requires = requiredUnits;
    wants = wantedUnits;
    after = wantedUnits ++ requiredUnits;
    unitConfig.RequiresMountsFor = rootPaths;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = command;
      LoadCredential = credentials;
      User = serviceName;
      Group = serviceName;
      SupplementaryGroups = [
        "media"
        planner.clientGroup
        worker.clientGroup
      ];
      StateDirectory = serviceName;
      StateDirectoryMode = "0700";
      TimeoutStartSec = "infinity";
      TimeoutStopSec = timeoutStopSec;
      UMask = "0077";
      AmbientCapabilities = "";
      CapabilityBoundingSet = "";
      InaccessiblePaths = [ "-/run/secrets" ];
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
      ReadOnlyPaths = rootPaths;
      ReadWritePaths = readWritePaths;
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

  systemd.timers.${serviceName} = {
    description = timerDescription;
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnActiveSec = "5m";
      OnUnitInactiveSec = interval;
      Unit = "${serviceName}.service";
    };
  };
}
