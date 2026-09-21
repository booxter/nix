{
  config,
  lib,
  ...
}:
let
  lidarr = config.host.lidarr;
  controller = if lidarr == null then null else lidarr.repair.controller;
  serviceName = "lidarr-repair-controller";
  command =
    if controller == null then
      ""
    else
      lib.escapeShellArgs [
        (lib.getExe controller.package)
        "--lidarr-url"
        "http://127.0.0.1:${toString config.services.lidarr.settings.server.port}"
        "--lidarr-api-key-file"
        "%d/lidarr-api-key"
        "--state-directory"
        "/var/lib/${serviceName}"
        "--request-timeout"
        "${toString controller.requestTimeoutSeconds}s"
      ];
in
{
  config = lib.mkIf (controller != null && controller.enable) {
    users.groups.${serviceName} = { };
    users.users.${serviceName} = {
      isSystemUser = true;
      group = serviceName;
      home = "/var/empty";
    };

    systemd.services.${serviceName} = {
      description = "Observe Lidarr import queue without applying repairs";
      requires = [
        "lidarr.service"
        "sops-install-secrets.service"
      ];
      after = [
        "lidarr.service"
        "sops-install-secrets.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = command;
        LoadCredential = [
          "lidarr-api-key:${config.sops.secrets."lidarr/apiKey".path}"
        ];
        User = serviceName;
        Group = serviceName;
        StateDirectory = serviceName;
        StateDirectoryMode = "0700";
        TimeoutStartSec = controller.requestTimeoutSeconds + 10;
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

    systemd.timers.${serviceName} = {
      description = "Periodically observe the Lidarr import queue";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnActiveSec = "5m";
        OnUnitInactiveSec = controller.interval;
        Unit = "${serviceName}.service";
      };
    };
  };
}
