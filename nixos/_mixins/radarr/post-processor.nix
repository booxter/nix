{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.radarr;
  enabled = cfg != null && cfg.agent.enable;
  package = pkgs.callPackage ../servarr/pkgs/arr-post-processor {
    atomicFileWrites = pkgs.atomic-file-writes;
    hermesRuns = pkgs.hermes-runs;
  };
  mediaDir = config.host.storage.claims.media.mountPoint;
  outputRoot = "${mediaDir}/.hermes-agent/radarr-repair";
  stateDir = "/var/lib/arr-post-processor-radarr";
  auditRoot = "${stateDir}/audit";
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile/arr-post-processor-radarr";
  metricsFile = "${nodeExporterTextfileDir}/arr-post-processor-radarr.prom";
  sourceRoots = {
    torrents = "${mediaDir}/torrents/radarr";
  }
  // lib.optionalAttrs (config.host.sabnzbd != null) {
    usenet-manual = "${mediaDir}/usenet/manual";
  };
  hermesUnit = "hermes-agent-radarr-repair.service";
  serviceDeps = [
    "radarr.service"
    hermesUnit
    "network-online.target"
  ];
in
{
  config = lib.mkIf enabled {
    host.observability.nodeExporter.textfile.directories.arr-post-processor-radarr =
      nodeExporterTextfileDir;

    host.storage.claims.media.attachments.arr-post-processor-radarr = { };

    systemd.tmpfiles.rules = [
      "d ${nodeExporterTextfileDir} 0755 radarr media - -"
    ];

    systemd.services.arr-post-processor-radarr = {
      description = "Repair stalled Radarr downloads with Hermes and import the result";
      wantedBy = [ "multi-user.target" ];
      wants = serviceDeps;
      after = serviceDeps;
      serviceConfig = {
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe package)
            "--processor"
            "radarr"
            "--arr-url"
            "http://127.0.0.1:${toString config.services.radarr.settings.server.port}"
            "--arr-config"
            "${cfg.stateDir}/config.xml"
            "--hermes-url"
            "http://127.0.0.1:8642"
            "--hermes-api-key-file"
            "%d/hermes-api-key"
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
            "--state-file"
            "${stateDir}/repair-state-v1.json"
            "--metrics-file"
            metricsFile
            "--interval-seconds"
            "30"
            "--settle-seconds"
            "60"
            "--request-timeout-seconds"
            "20"
            "--agent-timeout-seconds"
            "14400"
            "--command-timeout-seconds"
            "900"
          ]
        );
        LoadCredential = "hermes-api-key:/var/lib/hermes-agent-radarr-repair/.hermes/api-server.env";
        User = "radarr";
        Group = "media";
        # Keep processor artifacts private to the collaborating media group.
        UMask = "0007";
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
        IPAddressDeny = "any";
        IPAddressAllow = [
          "127.0.0.0/8"
          "::1/128"
        ];
        ReadWritePaths = [
          outputRoot
          nodeExporterTextfileDir
        ];
      };
    };
  };
}
