{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.hardware.storage.diskBays;
  textfileDir = config.host.observability.nodeExporter.textfile.directories.default;
  mapFile = "/etc/disk-bay-map.json";
  exporterPackage = pkgs.callPackage ./disk-bay-exporter {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  jsonMapping = map (
    mapping:
    removeAttrs mapping [ "column" ]
    // {
      col = mapping.column;
    }
  ) cfg.mapping;
in
{
  imports = [ ./disk-bays/assertions.nix ];

  config = lib.mkIf (cfg != null) {
    environment.etc."disk-bay-map.json".text = builtins.toJSON jsonMapping;

    systemd.services.disk-bay-exporter = lib.mkIf cfg.exporter.enable {
      description = "Export physical disk-bay mappings for node exporter";
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = utils.escapeSystemdExecArgs [
          (lib.getExe exporterPackage)
          "--bay-map"
          mapFile
          "--output-file"
          "${textfileDir}/disk-bays.prom"
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

    systemd.timers.disk-bay-exporter = lib.mkIf cfg.exporter.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "1min";
      };
    };

    systemd.tmpfiles.rules = lib.mkIf cfg.exporter.enable [
      "d ${textfileDir} 0755 root root - -"
    ];
  };
}
