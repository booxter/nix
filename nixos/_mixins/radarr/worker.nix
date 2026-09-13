{
  config,
  lib,
  utils,
  ...
}:
let
  worker = if config.host.radarr == null then null else config.host.radarr.repair.worker;
  serviceName = "radarr-repair-worker";
  serviceUser = serviceName;
  rootIDs = if worker == null then [ ] else builtins.attrNames worker.roots;
  rootPaths = if worker == null then [ ] else builtins.attrValues worker.roots;
  rootArguments = lib.concatMap (rootID: [
    "--root"
    "${rootID}=${worker.roots.${rootID}}"
  ]) rootIDs;
  command = utils.escapeSystemdExecArgs (
    [
      (lib.getExe' worker.package "radarr-repair-worker")
      "--socket"
      worker.socketPath
      "--state-directory"
      "/var/lib/${serviceName}"
      "--timeout"
      "${toString worker.probeTimeoutSeconds}s"
      "--join-timeout"
      "${toString worker.joinTimeoutSeconds}s"
      "--max-concurrent"
      (toString worker.maxConcurrent)
    ]
    ++ rootArguments
  );
  validRootID = rootID: builtins.match "^[a-z][a-z0-9_:-]{0,127}$" rootID != null;
in
{
  config = lib.mkIf (worker != null && worker.enable) {
    assertions = [
      {
        assertion = worker.roots != { };
        message = "Radarr repair worker requires at least one media root.";
      }
      {
        assertion = builtins.all validRootID rootIDs;
        message = "Radarr repair worker root IDs must be valid opaque identifiers.";
      }
      {
        assertion = builtins.length rootPaths == builtins.length (lib.unique rootPaths);
        message = "Radarr repair worker root paths must be unique.";
      }
      {
        assertion = builtins.all (path: builtins.dirOf path != path) rootPaths;
        message = "Radarr repair worker cannot expose the filesystem root.";
      }
    ];

    users.groups.${worker.clientGroup} = { };
    users.users.${serviceUser} = {
      isSystemUser = true;
      group = worker.clientGroup;
      home = "/var/empty";
    };

    systemd.services.${serviceName} = {
      description = "Perform isolated media operations for Radarr repair";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      unitConfig.RequiresMountsFor = rootPaths;
      serviceConfig = {
        ExecStart = command;
        User = serviceUser;
        Group = worker.clientGroup;
        SupplementaryGroups = [ "media" ];
        RuntimeDirectory = serviceName;
        RuntimeDirectoryMode = "0750";
        StateDirectory = serviceName;
        StateDirectoryMode = "0700";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStopSec = "10s";
        UMask = "0077";
        AmbientCapabilities = "";
        CapabilityBoundingSet = "";
        InaccessiblePaths = [ "-/run/secrets" ];
        IPAddressDeny = "any";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateNetwork = true;
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
        RemoveIPC = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
      };
    };
  };
}
