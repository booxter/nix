{
  config,
  lib,
  ...
}:
let
  lidarr = config.host.lidarr;
  controller = if lidarr == null then null else lidarr.repair.controller;
  planner = config.host.mediaRepair.planner;
  worker = config.host.mediaRepair.worker;
  serviceName = "lidarr-repair-controller";
  killSwitchFile = "/run/lidarr-repair-disable-apply";
  rootIDs = builtins.attrNames worker.roots;
  rootPaths = builtins.attrValues worker.roots;
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
        "--apply"
        "--kill-switch-file"
        killSwitchFile
      ]
      ++ actionArguments
    else
      [ ];
  command =
    if controller == null then
      ""
    else
      lib.escapeShellArgs (
        [
          (lib.getExe controller.package)
          "--lidarr-url"
          "http://127.0.0.1:${toString config.services.lidarr.settings.server.port}"
          "--lidarr-api-key-file"
          "%d/lidarr-api-key"
          "--worker-socket"
          worker.socketPath
          "--planner-socket"
          planner.socketPath
          "--state-directory"
          "/var/lib/${serviceName}"
          "--request-timeout"
          "${toString controller.requestTimeoutSeconds}s"
          "--worker-stage-timeout"
          "${toString (worker.joinTimeoutSeconds + 30)}s"
          "--planner-timeout"
          "${toString (planner.planningTimeoutSeconds + 30)}s"
        ]
        ++ modeArguments
        ++ rootArguments
      );
in
{
  config = lib.mkIf (controller != null && controller.enable) {
    assertions = [
      {
        assertion = worker.enable && planner.enable && worker.roots != { };
        message = "Lidarr repair requires the shared media worker and planner with roots.";
      }
      {
        assertion = !controller.apply.enable || controller.apply.allowedActions != [ ];
        message = "Lidarr repair apply mode requires at least one allowed action.";
      }
      {
        assertion = controller.apply.enable || controller.apply.allowedActions == [ ];
        message = "Lidarr repair actions can be allowed only when apply mode is enabled.";
      }
      {
        assertion =
          builtins.length controller.apply.allowedActions
          == builtins.length (lib.unique controller.apply.allowedActions);
        message = "Lidarr repair allowed actions must be unique.";
      }
    ];

    users.groups.${serviceName} = { };
    users.users.${serviceName} = {
      isSystemUser = true;
      group = serviceName;
      home = "/var/empty";
    };

    systemd.services.${serviceName} = {
      description =
        if controller.apply.enable then
          "Plan and apply permitted Lidarr import repairs"
        else
          "Plan Lidarr import repairs in shadow mode";
      requires = [
        "media-repair-planner.socket"
        "media-repair-worker.service"
        "lidarr.service"
        "sops-install-secrets.service"
      ];
      after = [
        "media-repair-planner.socket"
        "media-repair-worker.service"
        "lidarr.service"
        "sops-install-secrets.service"
      ];
      unitConfig.RequiresMountsFor = rootPaths;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = command;
        LoadCredential = [
          "lidarr-api-key:${config.sops.secrets."lidarr/apiKey".path}"
        ];
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
        TimeoutStopSec = "10s";
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
      description = "Periodically run the Lidarr repair controller";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnActiveSec = "5m";
        OnUnitInactiveSec = controller.interval;
        Unit = "${serviceName}.service";
      };
    };
  };
}
