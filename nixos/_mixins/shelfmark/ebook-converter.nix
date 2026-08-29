{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg converter;
  package = import ./ebook-converter { inherit pkgs; };
in
{
  config = lib.mkIf (cfg != null) {
    host.observability.nodeExporter.textfile.directories.ebook-converter = converter.metricsDir;

    users.users.${converter.user} = {
      group = converter.group;
      home = "/var/empty";
      isSystemUser = true;
    };

    systemd.tmpfiles.rules = [
      "d '${converter.stateDir}' 0770 ${converter.user} ${converter.group} - -"
      "z '${converter.stateDir}' 0770 ${converter.user} ${converter.group} - -"
      "d ${converter.metricsDir} 0755 ${converter.user} ${converter.group} - -"
      "r /var/lib/prometheus-node-exporter-textfile/ebook-converter.prom"
    ];

    host.storage.claims.${model.ebooks.storage.claim}.attachments.ebook-converter = { };

    systemd.services.ebook-converter = {
      description = "Convert library MOBI and AZW3 files to EPUB";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = utils.escapeSystemdExecArgs [
          (lib.getExe package)
          "--library-root"
          model.ebooks.path
          "--lock-root"
          converter.stateDir
          "--state-file"
          "${converter.stateDir}/state.json"
          "--metrics-file"
          converter.metricsFile
          "--interval-seconds"
          "30"
          "--settle-seconds"
          "30"
          "--max-attempts"
          "3"
        ];
        Environment = "XDG_CONFIG_HOME=${converter.stateDir}";
        User = converter.user;
        Group = converter.group;
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
        ReadWritePaths = [
          model.ebooks.path
          converter.stateDir
          converter.metricsDir
        ];
      };
    };
  };
}
