{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.radarr;
  package = pkgs.callPackage ../servarr/pkgs/arr-post-processor {
    atomicFileWrites = pkgs.atomic-file-writes;
    joinMediaParts = pkgs.join-media-parts;
  };
  mediaDir = config.host.storage.claims.media.mountPoint;
  workRoot = "${mediaDir}/.arr-post-processor/radarr-media-join";
  stateDir = "/var/lib/arr-post-processor-radarr";
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile/arr-post-processor-radarr";
  metricsFile = "${nodeExporterTextfileDir}/arr-post-processor-radarr.prom";
  allowedRoots = [
    "${mediaDir}/torrents/radarr"
  ]
  ++ lib.optional (config.host.sabnzbd != null) "${mediaDir}/usenet/manual";
  serviceDeps = [
    "radarr.service"
    "network-online.target"
  ];
in
{
  config = lib.mkIf (cfg != null) {
    host.observability.nodeExporter.textfile.directories.arr-post-processor-radarr =
      nodeExporterTextfileDir;

    host.storage.claims.media = {
      directories.".arr-post-processor/radarr-media-join".mode = "2775";
      attachments.arr-post-processor-radarr = { };
    };

    systemd.tmpfiles.rules = [
      "d ${nodeExporterTextfileDir} 0755 radarr media - -"
    ];

    systemd.services.arr-post-processor-radarr = {
      description = "Recover stalled Radarr downloads and import the result";
      wantedBy = [ "multi-user.target" ];
      wants = serviceDeps;
      after = serviceDeps;
      serviceConfig = {
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe package)
            "--processor"
            "radarr-media-join"
            "--arr-url"
            "http://127.0.0.1:${toString config.services.radarr.settings.server.port}"
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
            "60"
            "--request-timeout-seconds"
            "20"
            "--command-timeout-seconds"
            "14400"
          ]
        );
        User = "radarr";
        Group = "media";
        UMask = "0002";
        StateDirectory = "arr-post-processor-radarr";
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
