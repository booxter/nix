{
  config,
  lib,
  utils,
  ...
}:
let
  cfg = config.host.houndarr;
  textfileDir = config.host.observability.nodeExporter.textfile.directories.default;
  metricsFile = "${textfileDir}/houndarr-status.prom";
  command = utils.escapeSystemdExecArgs [
    (lib.getExe' cfg.toolsPackage "houndarr-status-collector")
    "--url"
    "http://127.0.0.1:${toString cfg.port}/api/status"
    "--metrics-file"
    metricsFile
  ];
in
{
  config = lib.mkIf (cfg.enable && cfg.observability.enable) {
    systemd = {
      services.houndarr-status-collector = {
        description = "Collect Houndarr scheduler and application status";
        wants = [ "houndarr.service" ];
        after = [ "houndarr.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = command;
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
          OnBootSec = cfg.observability.interval;
          OnUnitActiveSec = cfg.observability.interval;
          AccuracySec = "30s";
        };
      };

      tmpfiles.rules = [
        "d ${textfileDir} 0755 root root - -"
      ];
    };
  };
}
