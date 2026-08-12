{
  config,
  lib,
  utils,
  ...
}:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
in
{
  config = lib.mkIf cfg.enable {
    host.storage.claims.${model.library.storage.claim}.attachments.ebook-converter.unit =
      "ebook-converter";

    systemd.tmpfiles.rules = [
      "d '${cfg.stateDir}' 0770 ${cfg.user} ${cfg.group} - -"
      "z '${cfg.stateDir}' 0770 ${cfg.user} ${cfg.group} - -"
      "z ${model.metricsDir} 0775 root ${cfg.group} - -"
    ];

    users.users.${cfg.user} = {
      group = cfg.group;
      home = "/var/empty";
      isSystemUser = true;
      uid = config.host.accounts.users.${cfg.user}.uid;
    };

    systemd.services.ebook-converter = {
      description = "Convert library MOBI and AZW3 files to EPUB";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = utils.escapeSystemdExecArgs [
          (lib.getExe cfg.package)
          "watch"
          "--library-root"
          model.library.path
          "--lock-root"
          cfg.stateDir
          "--state-file"
          "${cfg.stateDir}/state.json"
          "--metrics-file"
          model.metricsFile
          "--interval-seconds"
          "30"
          "--settle-seconds"
          "30"
          "--max-attempts"
          "3"
        ];
        Environment = "XDG_CONFIG_HOME=${cfg.stateDir}";
        User = cfg.user;
        Group = cfg.group;
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
          cfg.stateDir
          model.metricsDir
        ];
      };
    };
  };
}
