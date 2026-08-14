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
        assertion = builtins.elem "amd" config.host.hardware.gpu.vendors;
        message = "host.hardware.gpu.collector requires an AMD GPU";
      }
    ];

    systemd.services.amdgpu-metrics = {
      description = "Collect AMD GPU metrics for Prometheus";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe metricsPackage} --output ${textfileDir}/amdgpu.prom";
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

    systemd.timers.amdgpu-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "30s";
        AccuracySec = "5s";
      };
    };

    systemd.tmpfiles.rules = [
      "d ${textfileDir} 0755 root root - -"
    ];
  };
}
