{
  config,
  lib,
  ...
}:
let
  planner = if config.host.radarr == null then null else config.host.radarr.repair.planner;
  serviceName = "radarr-repair-planner";
  serviceUser = serviceName;
  secretName = "radarr-repair/openrouter-api-key";
in
{
  config = lib.mkIf (planner != null && planner.enable) {
    assertions = [
      {
        assertion = planner.planningTimeoutSeconds > 2 * planner.attemptTimeoutSeconds;
        message = "Radarr repair planning timeout must cover both model attempts.";
      }
    ];

    users.groups = {
      ${serviceUser} = { };
      ${planner.clientGroup} = { };
    };
    users.users.${serviceUser} = {
      isSystemUser = true;
      group = serviceUser;
      home = "/var/empty";
    };

    sops.secrets.${secretName}.restartUnits = [ "${serviceName}.service" ];

    systemd.sockets.${serviceName} = {
      description = "Radarr repair planner API socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = planner.socketPath;
        RemoveOnStop = true;
        Service = "${serviceName}.service";
        SocketGroup = planner.clientGroup;
        SocketMode = "0660";
        SocketUser = serviceUser;
      };
    };

    systemd.services.${serviceName} = {
      description = "Plan Radarr import repairs";
      wants = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      requires = [ "${serviceName}.socket" ];
      after = [
        "network-online.target"
        "${serviceName}.socket"
        "sops-install-secrets.service"
      ];
      serviceConfig = {
        # %d expands to this service's private credentials directory.
        ExecStart = lib.escapeShellArgs [
          (lib.getExe' planner.package "radarr-repair-planner-serve")
          "--backend"
          "openrouter"
          "--model"
          planner.model
          "--openrouter-provider"
          planner.provider
          "--openrouter-api-key-file"
          "%d/openrouter-api-key"
          "--output-tokens"
          (toString planner.outputTokens)
          "--reasoning"
          planner.reasoningEffort
          "--timeout-seconds"
          (toString planner.attemptTimeoutSeconds)
          "--socket-fd"
          "3"
          "--planning-timeout-seconds"
          (toString planner.planningTimeoutSeconds)
        ];
        LoadCredential = "openrouter-api-key:${config.sops.secrets.${secretName}.path}";
        User = serviceUser;
        Group = serviceUser;
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStopSec = "35s";
        UMask = "0077";
        AmbientCapabilities = "";
        CapabilityBoundingSet = "";
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
  };
}
