{
  config,
  lib,
  pkgs,
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

    host.observability.nodeExporter.textfile.periodicProducers = lib.mkIf observabilityEnabled {
      hba-metrics = {
        description = "Export storage-controller metrics for node exporter";
        after = [ "local-fs.target" ];
        command = [
          (lib.getExe pkgs.storage-observability)
          "--bay-map"
          bayMapFile
          "--output-file"
          "${textfileDir}/hba.prom"
        ];
        interval = "1min";
        onBootSec = "45s";
      };
    };
  };
}
