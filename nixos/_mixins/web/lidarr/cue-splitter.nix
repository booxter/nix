{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  lidarrCfg = config.services.lidarr;
  cfg = lidarrCfg.cueSplitter;
  mediaDir = lidarrCfg.mediaDir;
  mediaExport = hostInventory.storage.nfs.exports.media;
  mediaLayout = mediaExport.layout;
  mediaGroup = mediaExport.sharedGroup.name;
  transmissionDir = "${mediaDir}/${mediaLayout.transmission.root}";
  sabnzbdCompleteDir = "${mediaDir}/${mediaLayout.sabnzbd.complete}";
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
  options.services.lidarr.cueSplitter = {
    enable = lib.mkEnableOption "Lidarr CUE splitting";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./packages/lidarr-cue-splitter {
        atomicFileWrites = pkgs.atomic-file-writes;
      };
      description = "Package providing the Lidarr CUE splitter.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lidarrCfg.enable;
        message = "Lidarr CUE splitting requires Lidarr on the same host.";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${workRoot} 2775 lidarr ${mediaGroup} - -"
      "z ${nodeExporterTextfileDir} 0775 root ${mediaGroup} - -"
    ];

    systemd.services.lidarr-cue-splitter = {
      description = "Split completed Lidarr CUE images and import their tracks";
      wantedBy = [ "multi-user.target" ];
      wants = serviceDeps;
      after = serviceDeps;
      unitConfig.RequiresMountsFor = mediaDir;
      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          (lib.getExe cfg.package)
          "--lidarr-url"
          "http://127.0.0.1:${toString lidarrCfg.settings.server.port}"
          "--lidarr-config"
          "${lidarrCfg.dataDir}/config.xml"
          "--allowed-root"
          transmissionDir
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
        Group = mediaGroup;
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
