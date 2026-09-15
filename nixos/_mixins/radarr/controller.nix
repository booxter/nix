{
  config,
  lib,
  ...
}:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model)
    controller
    planner
    sabnzbd
    selectedDownloadClients
    transmission
    worker
    ;
  serviceName = "radarr-repair-controller";
  killSwitchFile = "/run/radarr-repair-disable-apply";
  metricsFile = "${controller.metricsDirectory}/radarr-repair.prom";
  sabnzbdSecret = if sabnzbd == null then null else sabnzbd.authentication.secret;
  downloadClientArguments =
    lib.optionals (transmission != null) [
      "--transmission-url"
      transmission.endpoint
    ]
    ++ lib.optionals (sabnzbd != null) [
      "--sabnzbd-url"
      sabnzbd.endpoint
      "--sabnzbd-api-key-file"
      "%d/sabnzbd-api-key"
    ];
  downloadClientUnits = map (client: "${client.implementation}.service") selectedDownloadClients;
  downloadClientCredentials = lib.optionals (sabnzbdSecret != null) [
    "sabnzbd-api-key:${config.sops.secrets.${sabnzbdSecret}.path}"
  ];
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
  allowedDownloadClientArguments = lib.concatMap (client: [
    "--allow-download-client"
    client
  ]) controller.apply.allowedDownloadClients;
  modeArguments =
    if controller.apply.enable then
      [
        "run"
        "--apply"
        "--kill-switch-file"
        killSwitchFile
      ]
      ++ actionArguments
      ++ allowedDownloadClientArguments
    else
      [ "shadow" ];
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
      "--worker-socket"
      worker.socketPath
      "--planner-socket"
      planner.socketPath
      "--state-directory"
      "/var/lib/${serviceName}"
      "--metrics-file"
      metricsFile
      "--stabilization"
      controller.stabilization
      "--planner-timeout"
      "${toString plannerTimeoutSeconds}s"
    ]
    ++ downloadClientArguments
    ++ rootArguments
  );
in
{
  config = lib.mkIf (controller != null && controller.enable) {
    users.groups.${serviceName} = { };
    users.users.${serviceName} = {
      isSystemUser = true;
      group = serviceName;
      home = "/var/empty";
    };

    systemd.tmpfiles.rules = [
      "d ${controller.metricsDirectory} 0755 ${serviceName} ${serviceName} - -"
    ];

    sops.secrets = lib.optionalAttrs (sabnzbdSecret != null) {
      ${sabnzbdSecret}.restartUnits = [ "${serviceName}.service" ];
    };

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
      ]
      ++ downloadClientUnits;
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "radarr-repair-planner.socket"
        "radarr-repair-worker.service"
        "radarr.service"
        "sops-install-secrets.service"
      ]
      ++ downloadClientUnits;
      unitConfig.RequiresMountsFor = rootPaths;
      serviceConfig = {
        Type = "oneshot";
        # %d expands to this service's private credentials directory.
        ExecStart = command;
        LoadCredential = [
          "radarr-api-key:${config.sops.secrets."radarr/apiKey".path}"
        ]
        ++ downloadClientCredentials;
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
