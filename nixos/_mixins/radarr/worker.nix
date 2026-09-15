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
  knownWritableRootIDs =
    if worker == null then
      [ ]
    else
      builtins.filter (rootID: builtins.hasAttr rootID worker.roots) worker.writableRoots;
  writableRootPaths = map (rootID: worker.roots.${rootID}) knownWritableRootIDs;
  readOnlyRootPaths =
    if worker == null then [ ] else builtins.attrValues (removeAttrs worker.roots worker.writableRoots);
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
in
{
  config = lib.mkIf (worker != null && worker.enable) {
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
        ReadOnlyPaths = readOnlyRootPaths;
        ReadWritePaths = writableRootPaths;
        RemoveIPC = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        # RestrictSUIDSGID blocks openat2 because seccomp cannot inspect
        # open_how.mode: https://github.com/systemd/systemd/issues/38711
        SystemCallArchitectures = "native";
      };
    };
  };
}
