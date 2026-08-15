{
  config,
  lib,
  ...
}:
let
  cfg = config.host.houndarr;
  textfileDir = config.host.observability.nodeExporter.textfile.directories.default;
  metricsFile = "${textfileDir}/houndarr-status.prom";
  command = [
    (lib.getExe' cfg.toolsPackage "houndarr-status-collector")
    "--url"
    "http://127.0.0.1:${toString cfg.port}/api/status"
    "--metrics-file"
    metricsFile
  ];
in
{
  config = lib.mkIf (cfg.enable && cfg.observability.enable) {
    host.observability.nodeExporter.textfile.periodicProducers.houndarr-status-collector = {
      description = "Collect Houndarr scheduler and application status";
      wants = [ "houndarr.service" ];
      after = [ "houndarr.service" ];
      inherit command;
      interval = cfg.observability.interval;
      accuracySec = "30s";
      addressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
    };
  };
}
