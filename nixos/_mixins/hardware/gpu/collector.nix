{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.hardware.gpu.collector;
  metricsPackage = pkgs.callPackage ./amdgpu-metrics { };
  textfileDir = config.host.observability.nodeExporter.textfile.directories.default;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.host.hardware.gpu.vendor == "amd";
        message = "host.hardware.gpu.collector requires an AMD GPU";
      }
    ];

    host.observability.nodeExporter.textfile.periodicProducers.amdgpu-metrics = {
      description = "Collect AMD GPU metrics for Prometheus";
      command = [
        (lib.getExe metricsPackage)
        "--output"
        "${textfileDir}/amdgpu.prom"
      ];
      interval = "30s";
      onBootSec = "2m";
      accuracySec = "5s";
    };
  };
}
