{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.hardware.storage.mdraid;
  observabilityEnabled = config.host.observability.enable;
  textfileDir = config.host.observability.nodeExporter.textfile.directories.default;
in
{
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        boot.swraid = {
          enable = true;
          mdadmConf = "PROGRAM ${pkgs.util-linux}/bin/logger -t mdadm-monitor";
        };

        boot.kernel.sysctl = lib.mkIf (cfg.recoverySpeedLimitMax != null) {
          "dev.raid.speed_limit_max" = cfg.recoverySpeedLimitMax;
        };

        environment.systemPackages = [ pkgs.mdadm ];
      }
      (lib.mkIf observabilityEnabled {
        # node_exporter cannot parse transient raid_disks values such as
        # "11 (10)" during reshape, so use the dedicated sysfs collector.
        services.prometheus.exporters.node.extraFlags = [ "--no-collector.mdadm" ];

        systemd.services.mdraid-metrics = {
          description = "Export Linux MD status for node exporter";
          after = [ "local-fs.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = utils.escapeSystemdExecArgs [
              (lib.getExe' pkgs.storage-observability "storage-md-metrics")
              "--output-file"
              "${textfileDir}/md-sync.prom"
            ];
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            ReadWritePaths = [ textfileDir ];
            RestrictAddressFamilies = [ "AF_UNIX" ];
            RestrictRealtime = true;
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
          };
        };

        systemd.timers.mdraid-metrics = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "30s";
            OnUnitActiveSec = "1min";
          };
        };

        systemd.tmpfiles.rules = [
          "d ${textfileDir} 0755 root root - -"
        ];
      })
    ]
  );
}
