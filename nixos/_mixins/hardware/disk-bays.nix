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

  config = lib.mkIf (cfg != null) (
    lib.mkMerge [
      {
        environment.etc."disk-bay-map.json".text = builtins.toJSON jsonMapping;
      }
      (lib.mkIf cfg.exporter.enable {
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
      })
    ]
  );
}
