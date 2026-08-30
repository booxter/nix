{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.lidarr;
  package = pkgs.callPackage ../servarr/pkgs/arr-post-processor {
    atomicFileWrites = pkgs.atomic-file-writes;
    joinMediaParts = pkgs.join-media-parts;
  };
  mediaDir = config.host.storage.claims.media.mountPoint;
  workRoot = "${mediaDir}/.arr-post-processor/lidarr";
  # Keep the existing state directory across the service rename.
  stateDir = "/var/lib/lidarr-cue-splitter";
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile/arr-post-processor-lidarr";
  metricsFile = "${nodeExporterTextfileDir}/arr-post-processor-lidarr.prom";
  allowedRoots = [
    "${mediaDir}/torrents"
  ]
  ++ lib.optional (config.host.sabnzbd != null) "${mediaDir}/usenet/manual";
  serviceDeps = [
    "lidarr.service"
    "network-online.target"
  ];
in
{
  config = lib.mkIf (cfg != null) {
    host.observability.nodeExporter.textfile.directories.arr-post-processor-lidarr =
      nodeExporterTextfileDir;

    host.storage.claims.media = {
      directories.".arr-post-processor/lidarr".mode = "2775";
      attachments.arr-post-processor-lidarr = { };
    };

    systemd.tmpfiles.rules = [
      "d ${nodeExporterTextfileDir} 0755 lidarr media - -"
      "D ${mediaDir}/.cue-splitter-work 2775 lidarr media 7d"
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
          mediaDir
          nodeExporterTextfileDir
        ];
      };
    };
  };
}
