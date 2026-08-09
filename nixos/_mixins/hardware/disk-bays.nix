{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.hardware.storage.diskBays;
  textfileDir = config.host.observability.nodeExporter.textfile.directory;
  mapFile = "/etc/disk-bay-map.json";
  exporterPackage = pkgs.callPackage ./disk-bay-exporter {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  jsonMapping = map (
    mapping:
    builtins.removeAttrs mapping [ "column" ]
    // {
      col = mapping.column;
    }
  ) cfg.mapping;
  positions = map (mapping: "${toString mapping.row}:${toString mapping.column}") cfg.mapping;
  unique = values: builtins.length values == builtins.length (lib.unique values);
in
{
  config = lib.mkIf (cfg != null && cfg.exporter.enable) {
    assertions = [
      {
        assertion = config.host.observability.enable;
        message = "disk-bay metrics export requires host.observability.enable";
      }
      {
        assertion = cfg.mapping != [ ];
        message = "disk-bay metrics export requires a non-empty disk-bay mapping";
      }
      {
        assertion = lib.all (mapping: mapping.row <= cfg.rows) cfg.mapping;
        message = "disk-bay mapping rows must fit within the configured layout";
      }
      {
        assertion = lib.all (mapping: mapping.column <= cfg.columns) cfg.mapping;
        message = "disk-bay mapping columns must fit within the configured layout";
      }
      {
        assertion = unique (map (mapping: mapping.bay) cfg.mapping);
        message = "disk-bay mappings must use unique bay numbers";
      }
      {
        assertion = unique positions;
        message = "disk-bay mappings must use unique physical positions";
      }
      {
        assertion = unique (map (mapping: mapping.serial) cfg.mapping);
        message = "disk-bay mappings must use unique drive serials";
      }
    ];

    environment.etc."disk-bay-map.json".text = builtins.toJSON jsonMapping;

    systemd.services.disk-bay-exporter = {
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

    systemd.timers.disk-bay-exporter = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "1min";
      };
    };

    systemd.tmpfiles.rules = [
      "d ${textfileDir} 0755 root root - -"
    ];
  };
}
