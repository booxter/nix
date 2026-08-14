{
  config,
  lib,
  ...
}:
let
  cfg = config.host.lidarr;
  mediaDir = config.host.storage.claims.${cfg.storage.claim}.mountPoint;
  workRoot = "${mediaDir}/.cue-splitter-work";
  stateDir = "/var/lib/lidarr-cue-splitter";
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  metricsFile = "${nodeExporterTextfileDir}/lidarr-cue-splitter.prom";
  allowedRoots = [
    "${mediaDir}/torrents"
  ]
  ++ lib.optional config.host.sabnzbd.enable config.host.sabnzbd.completeDir;
  serviceDeps = [
    "lidarr.service"
    "network-online.target"
  ];
in
{
  config = lib.mkIf (cfg.enable && cfg.cueSplitter.enable) {
    host.storage.claims.${cfg.storage.claim} = {
      directories.".cue-splitter-work".mode = "2775";
      attachments.lidarr-cue-splitter.unit = "lidarr-cue-splitter";
    };

    systemd.tmpfiles.rules = [
      "z ${nodeExporterTextfileDir} 0775 root ${cfg.group} - -"
    ];

    systemd.services.lidarr-cue-splitter = {
      description = "Split completed Lidarr CUE images and import their tracks";
      wantedBy = [ "multi-user.target" ];
      wants = serviceDeps;
      after = serviceDeps;
      serviceConfig = {
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe cfg.cueSplitter.package)
            "--lidarr-url"
            "http://127.0.0.1:${toString config.services.lidarr.settings.server.port}"
            "--lidarr-config"
            "${cfg.stateDir}/config.xml"
          ]
          ++ lib.concatMap (root: [
            "--allowed-root"
            root
          ]) allowedRoots
          ++ [
            "--work-root"
            workRoot
            "--state-file"
            "${stateDir}/state.json"
            "--metrics-file"
            metricsFile
            "--interval-seconds"
            "30"
            "--settle-seconds"
            "30"
            "--request-timeout-seconds"
            "20"
            "--command-timeout-seconds"
            "900"
          ]
        );
        User = cfg.user;
        Group = cfg.group;
        UMask = "0002";
        StateDirectory = "lidarr-cue-splitter";
        StateDirectoryMode = "0750";
        Restart = "always";
        RestartSec = "10s";
        Nice = 10;
        IOSchedulingClass = "idle";
        CPUQuota = "200%";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
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
        ReadWritePaths = [
          mediaDir
          nodeExporterTextfileDir
        ];
      };
    };
  };
}
