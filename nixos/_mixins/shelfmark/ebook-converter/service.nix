{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
  package = import ./package { inherit pkgs; };
in
{
  config = lib.mkIf (cfg != null) {
    host.storage.claims.${model.library.storage.claim}.attachments.ebook-converter.unit =
      "ebook-converter";

    systemd.tmpfiles.rules = [
      "d '${model.stateDir}' 0770 ${model.user} ${model.group} - -"
      "z '${model.stateDir}' 0770 ${model.user} ${model.group} - -"
      "z ${model.metricsDir} 0775 root ${model.group} - -"
    ];

    users.users.${model.user} = {
      group = model.group;
      home = "/var/empty";
      isSystemUser = true;
    };

    systemd.services.ebook-converter = {
      description = "Convert library MOBI and AZW3 files to EPUB";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = utils.escapeSystemdExecArgs [
          (lib.getExe package)
          "watch"
          "--library-root"
          model.library.path
          "--lock-root"
          model.stateDir
          "--state-file"
          "${model.stateDir}/state.json"
          "--metrics-file"
          model.metricsFile
          "--interval-seconds"
          "30"
          "--settle-seconds"
          "30"
          "--max-attempts"
          "3"
        ];
        Environment = "XDG_CONFIG_HOME=${model.stateDir}";
        User = model.user;
        Group = model.group;
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
          model.library.path
          model.stateDir
          model.metricsDir
        ];
      };
    };
  };
}
