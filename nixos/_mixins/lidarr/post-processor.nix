{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.lidarr;
  enabled = cfg != null && cfg.agent.enable;
  package = pkgs.callPackage ../servarr/pkgs/arr-post-processor {
    atomicFileWrites = pkgs.atomic-file-writes;
    hermesRuns = pkgs.hermes-runs;
  };
  mediaDir = config.host.storage.claims.media.mountPoint;
  outputRoot = "${mediaDir}/.hermes-agent/lidarr-repair";
  # Keep the existing state directory across the service rename.
  stateDir = "/var/lib/lidarr-cue-splitter";
  auditRoot = "${stateDir}/audit";
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile/arr-post-processor-lidarr";
  metricsFile = "${nodeExporterTextfileDir}/arr-post-processor-lidarr.prom";
  sourceRoots = {
    torrents = "${mediaDir}/torrents/lidarr";
  }
  // lib.optionalAttrs (config.host.sabnzbd != null) {
    usenet-manual = "${mediaDir}/usenet/manual";
  };
  hermesUnit = "hermes-agent-lidarr-repair.service";
  serviceDeps = [
    "lidarr.service"
    hermesUnit
    "network-online.target"
  ];
in
{
  config = lib.mkIf enabled {
    host.observability.nodeExporter.textfile.directories.arr-post-processor-lidarr =
      nodeExporterTextfileDir;

    host.storage.claims.media.attachments.arr-post-processor-lidarr = { };

    systemd.tmpfiles.rules = [
      "d ${nodeExporterTextfileDir} 0755 lidarr media - -"
    ];

    systemd.services.arr-post-processor-lidarr = {
      description = "Recover stalled Lidarr downloads and import the result";
      wantedBy = [ "multi-user.target" ];
      wants = serviceDeps;
      after = serviceDeps;
      serviceConfig = {
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe package)
            "--processor"
            "lidarr"
            "--arr-url"
            "http://127.0.0.1:${toString config.services.lidarr.settings.server.port}"
            "--arr-config"
            "${cfg.stateDir}/config.xml"
          ]
          ++ lib.optional cfg.agent.shadow "--shadow"
          ++ lib.concatLists (
            lib.mapAttrsToList (name: root: [
              "--source-root"
              "${name}=${root}"
            ]) sourceRoots
          )
          ++ [
            "--output-root"
            outputRoot
            "--audit-root"
            auditRoot
            "--hermes-url"
            "http://127.0.0.1:8643"
            "--hermes-api-key-file"
            "%d/hermes-api-key"
            "--state-file"
            "${stateDir}/repair-state-v1.json"
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
            "--agent-timeout-seconds"
            "14400"
          ]
        );
        LoadCredential = "hermes-api-key:/var/lib/hermes-agent-lidarr-repair/.hermes/api-server.env";
        User = "lidarr";
        Group = "media";
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
          outputRoot
          nodeExporterTextfileDir
        ]
        ++ builtins.attrValues sourceRoots;
      };
    };
  };
}
