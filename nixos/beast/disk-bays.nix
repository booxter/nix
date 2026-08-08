{
  beastPkgs,
  config,
  lib,
  utils,
  ...
}:
let
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";
  bayMapName = "disk-bay-map.json";
  bayMapPath = "/etc/${bayMapName}";
  diskBayExportCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' beastPkgs.storage-observability "storage-disk-bay-metrics")
    "--bay-map"
    bayMapPath
    "--output-file"
    "${textfileDir}/disk-bays.prom"
  ];
  hbaExportCommand = lib.escapeShellArgs [
    (lib.getExe beastPkgs.storage-observability)
    "--bay-map"
    bayMapPath
    "--output-file"
    "${textfileDir}/hba.prom"
  ];
in
{
  environment.etc.${bayMapName}.text = builtins.toJSON config.host.storage.diskBays.disks;

  systemd.services.storage-disk-bay-export = {
    description = "Export disk bay mapping for node exporter";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = diskBayExportCommand;
    };
  };

  systemd.timers.storage-disk-bay-export = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "1min";
      Unit = "storage-disk-bay-export.service";
    };
  };

  systemd.services.storage-hba-export = {
    description = "Export HBA metrics for node exporter";
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = hbaExportCommand;
    };
  };

  systemd.timers.storage-hba-export = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "45s";
      OnUnitActiveSec = "1min";
      Unit = "storage-hba-export.service";
    };
  };
}
