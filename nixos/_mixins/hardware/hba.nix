{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.hardware.storage.hba;
  diskBays = config.host.hardware.storage.diskBays;
  observabilityEnabled = config.host.observability.enable;
  textfileDir = config.host.observability.nodeExporter.textfile.directories.default;
  bayMapFile =
    if diskBays == null then
      pkgs.writeText "empty-disk-bay-map.json" "[]"
    else
      "/etc/disk-bay-map.json";
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.storcli ];

    systemd.services.hba-metrics = lib.mkIf observabilityEnabled {
      description = "Export storage-controller metrics for node exporter";
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = utils.escapeSystemdExecArgs [
          (lib.getExe pkgs.storage-observability)
          "--bay-map"
          bayMapFile
          "--output-file"
          "${textfileDir}/hba.prom"
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

    systemd.timers.hba-metrics = lib.mkIf observabilityEnabled {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "45s";
        OnUnitActiveSec = "1min";
      };
    };

    systemd.tmpfiles.rules = lib.mkIf observabilityEnabled [
      "d ${textfileDir} 0755 root root - -"
    ];
  };
}
