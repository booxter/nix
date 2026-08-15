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
  unique = values: builtins.length values == builtins.length (lib.unique values);
  positions = map (mapping: "${toString mapping.row}:${toString mapping.column}") cfg.mapping;
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
  config = lib.mkIf (cfg != null) {
    assertions = [
      {
        assertion = cfg.mapping != [ ];
        message = "disk-bay layout requires a non-empty mapping";
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

    host.observability.nodeExporter.textfile.periodicProducers =
      lib.mkIf config.host.observability.enable
        {
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
