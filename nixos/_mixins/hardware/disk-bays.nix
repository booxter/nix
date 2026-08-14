{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.hardware.storage.diskBays;
  textfileDir = config.host.observability.nodeExporter.textfile.directories.default;
  mapFile = "/etc/disk-bay-map.json";
  exporterPackage = pkgs.callPackage ./disk-bay-exporter {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  jsonMapping = map (mapping: {
    inherit (mapping)
      bay
      model
      row
      serial
      ;
    col = mapping.column;
  }) cfg.mapping;
in
{
  imports = [ ./disk-bays/assertions.nix ];

  config = lib.mkIf (cfg != null) {
    environment.etc."disk-bay-map.json".text = builtins.toJSON jsonMapping;

    host.observability.nodeExporter.textfile.periodicProducers = lib.mkIf cfg.exporter.enable {
      disk-bay-exporter = {
        description = "Export physical disk-bay mappings for node exporter";
        after = [ "local-fs.target" ];
        command = [
          (lib.getExe exporterPackage)
          "--bay-map"
          mapFile
          "--output-file"
          "${textfileDir}/disk-bays.prom"
        ];
        interval = "1min";
        onBootSec = "30s";
      };
    };
  };
}
