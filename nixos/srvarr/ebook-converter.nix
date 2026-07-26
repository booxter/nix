{
  config,
  lib,
  srvarrPkgs,
  ...
}:
let
  mediaDir = config.host.srvarrPaths.mediaDir;
  booksDir = "${mediaDir}/library/books";
  stateDir = "/var/lib/ebook-converter";
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  metricsFile = "${nodeExporterTextfileDir}/ebook-converter.prom";
in
{
  systemd.tmpfiles.rules = [
    "d '${stateDir}' 0770 shelfmark media - -"
    "z ${nodeExporterTextfileDir} 0775 root media - -"
  ];

  systemd.services.ebook-converter = {
    description = "Convert library MOBI and AZW3 files to EPUB";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    unitConfig.RequiresMountsFor = booksDir;
    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe srvarrPkgs.ebook-converter)
        "watch"
        "--library-root"
        booksDir
        "--lock-root"
        stateDir
        "--state-file"
        "${stateDir}/state.json"
        "--metrics-file"
        metricsFile
        "--interval-seconds"
        "30"
        "--settle-seconds"
        "30"
        "--max-attempts"
        "3"
      ];
      Environment = "XDG_CONFIG_HOME=${stateDir}";
      User = "shelfmark";
      Group = "media";
      UMask = "0002";
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
      RestrictAddressFamilies = [ "AF_UNIX" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      RemoveIPC = true;
      InaccessiblePaths = [
        "${mediaDir}/torrents"
        "${mediaDir}/usenet"
      ];
      ReadWritePaths = [
        booksDir
        stateDir
        nodeExporterTextfileDir
      ];
    };
  };
}
