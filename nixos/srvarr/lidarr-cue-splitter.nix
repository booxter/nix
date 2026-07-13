{
  config,
  lib,
  srvarrPkgs,
  ...
}:
let
  mediaDir = config.host.srvarrPaths.mediaDir;
  sabnzbdCompleteDir = config.services.sabnzbd.settings.misc.complete_dir;
  lidarrStateDir = "${config.host.srvarrPaths.stateDir}/lidarr";
  stateDir = "/var/lib/lidarr-cue-splitter";
  workRoot = "${mediaDir}/.cue-splitter-work";
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  metricsFile = "${nodeExporterTextfileDir}/lidarr-cue-splitter.prom";
  serviceDeps = [
    "lidarr.service"
    "network-online.target"
  ];
in
{
  systemd.tmpfiles.rules = [
    "d ${workRoot} 2775 lidarr media - -"
    "z ${nodeExporterTextfileDir} 0775 root media - -"
  ];

  systemd.services.lidarr-cue-splitter = {
    description = "Split completed Lidarr CUE images and import their tracks";
    wantedBy = [ "multi-user.target" ];
    wants = serviceDeps;
    after = serviceDeps;
    unitConfig.RequiresMountsFor = mediaDir;
    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe srvarrPkgs.lidarr-cue-splitter)
        "--lidarr-url"
        "http://127.0.0.1:${toString config.services.lidarr.settings.server.port}"
        "--lidarr-config"
        "${lidarrStateDir}/config.xml"
        "--allowed-root"
        "${mediaDir}/torrents"
        "--allowed-root"
        sabnzbdCompleteDir
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
      ];
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
}
