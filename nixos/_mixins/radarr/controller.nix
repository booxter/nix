{
  config,
  lib,
  ...
}:
let
  radarr = config.host.radarr;
  controller = if radarr == null then null else radarr.repair.controller;
  planner = if radarr == null then null else radarr.repair.planner;
  worker = if radarr == null then null else radarr.repair.worker;
  serviceName = "radarr-repair-controller";
  killSwitchFile = "/run/radarr-repair-disable-apply";
  metricsFile = "${controller.metricsDirectory}/radarr-repair.prom";
  rootIDs = if worker == null then [ ] else builtins.attrNames worker.roots;
  rootPaths = if worker == null then [ ] else builtins.attrValues worker.roots;
  rootArguments = lib.concatMap (rootID: [
    "--worker-root"
    "${rootID}=${worker.roots.${rootID}}"
  ]) rootIDs;
  actionArguments = lib.concatMap (action: [
    "--allow-action"
    action
  ]) controller.apply.allowedActions;
  modeArguments =
    if controller.apply.enable then
      [
        "run"
        "--apply"
        "--kill-switch-file"
        killSwitchFile
      ]
      ++ actionArguments
    else
      [ "shadow" ];
  joinAllowed = builtins.elem "join_parts_v1" controller.apply.allowedActions;
  transmissionURL = if controller.transmissionUrl == null then "" else controller.transmissionUrl;
  plannerTimeoutSeconds = planner.planningTimeoutSeconds + 30;
  command = lib.escapeShellArgs (
    [
      (lib.getExe controller.package)
    ]
    ++ modeArguments
    ++ [
      "--radarr-url"
      "http://127.0.0.1:${toString config.services.radarr.settings.server.port}"
      "--radarr-api-key-file"
      "%d/radarr-api-key"
      "--transmission-url"
      transmissionURL
      "--worker-socket"
      worker.socketPath
      "--planner-socket"
      planner.socketPath
      "--state-directory"
      "/var/lib/${serviceName}"
      "--metrics-file"
      metricsFile
      "--planner-timeout"
      "${toString plannerTimeoutSeconds}s"
    ]
    ++ rootArguments
  );
in
{
  config = lib.mkIf (controller != null && controller.enable) {
    assertions = [
      {
        assertion = controller.transmissionUrl != null;
        message = "Radarr repair controller requires a Transmission RPC URL.";
      }
      {
        assertion = worker.enable;
        message = "Radarr repair controller requires the media probe worker.";
      }
      {
        assertion = planner.enable;
        message = "Radarr repair controller requires the repair planner.";
      }
      {
        assertion = !controller.apply.enable || controller.apply.allowedActions != [ ];
        message = "Radarr repair apply mode requires at least one allowed action.";
      }
      {
        assertion = controller.apply.enable || controller.apply.allowedActions == [ ];
        message = "Radarr repair actions can be allowed only when apply mode is enabled.";
      }
      {
        assertion =
          builtins.length controller.apply.allowedActions
          == builtins.length (lib.unique controller.apply.allowedActions);
        message = "Radarr repair allowed actions must be unique.";
      }
      {
        assertion =
          !joinAllowed || builtins.all (rootID: builtins.elem rootID worker.writableRoots) rootIDs;
        message = "Automatic joins require every worker root to permit staged media writes.";
      }
    ];

    users.groups.${serviceName} = { };
    users.users.${serviceName} = {
      isSystemUser = true;
      group = serviceName;
      home = "/var/empty";
    };

    systemd.tmpfiles.rules = [
      "d ${controller.metricsDirectory} 0755 ${serviceName} ${serviceName} - -"
    ];

    systemd.services.${serviceName} = {
      description =
        if controller.apply.enable then
          "Plan and apply permitted Radarr import repairs"
        else
          "Plan Radarr import repairs in shadow mode";
      requires = [
        "radarr-repair-planner.socket"
        "radarr-repair-worker.service"
        "radarr.service"
        "sops-install-secrets.service"
        "transmission.service"
      ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "radarr-repair-planner.socket"
        "radarr-repair-worker.service"
        "radarr.service"
        "sops-install-secrets.service"
        "transmission.service"
      ];
      unitConfig.RequiresMountsFor = rootPaths;
      serviceConfig = {
        Type = "oneshot";
        # %d expands to this service's private credentials directory.
        ExecStart = command;
        LoadCredential = "radarr-api-key:${config.sops.secrets."radarr/apiKey".path}";
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
        TimeoutStopSec = "35s";
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
        ReadWritePaths = [ controller.metricsDirectory ];
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
      description = "Periodically run the Radarr repair controller";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnActiveSec = "5m";
        OnUnitInactiveSec = controller.interval;
        Unit = "${serviceName}.service";
      };
    };
  };
}
