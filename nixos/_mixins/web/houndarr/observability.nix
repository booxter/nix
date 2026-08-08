{
  config,
  lib,
  utils,
  ...
}:
let
  cfg = config.services.houndarr;
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";
  metricsFile = "${textfileDir}/houndarr-status.prom";
  collectorCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' cfg.tools.package "houndarr-status-collector")
    "--url"
    "${cfg.localUrl}/api/status"
    "--metrics-file"
    metricsFile
  ];
in
{
  config = lib.mkIf cfg.enable {
    systemd = {
      services.houndarr-status-collector = {
        description = "Collect Houndarr scheduler and Arr-instance status";
        wants = [ "houndarr.service" ];
        after = [ "houndarr.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = collectorCommand;
          User = "root";
          Group = "root";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ textfileDir ];
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
          ];
        };
      };

      timers.houndarr-status-collector = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2m";
          OnUnitActiveSec = "2m";
          AccuracySec = "30s";
        };
      };

      tmpfiles.rules = [
        "d ${textfileDir} 0755 root root - -"
      ];
    };
  };
}
