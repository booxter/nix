{ lib, ... }:
{
  options.host.hardware.storage.diskBays = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          rows = lib.mkOption {
            type = lib.types.ints.positive;
            description = "Number of physical disk-bay rows.";
          };
          columns = lib.mkOption {
            type = lib.types.ints.positive;
            description = "Number of physical disk-bay columns.";
          };
        };
      }
    );
    default = null;
    description = "Physical disk-bay layout exposed to fleet consumers.";
  };
}
