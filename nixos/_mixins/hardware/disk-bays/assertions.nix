{ config, lib, ... }:
let
  cfg = config.host.hardware.storage.diskBays;
  unique = values: builtins.length values == builtins.length (lib.unique values);
  positions = map (mapping: "${toString mapping.row}:${toString mapping.column}") cfg.mapping;
in
{
  assertions = lib.optionals (cfg != null) (
    [
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
    ]
    ++ lib.optionals cfg.exporter.enable [
      {
        assertion = cfg.mapping != [ ];
        message = "disk-bay metrics export requires a non-empty disk-bay mapping";
      }
    ]
  );
}
