{ lib, ... }:
{
  options.host.pinepods = lib.mkOption {
    type = lib.types.nullOr (lib.types.submodule { });
    default = null;
    description = "PinePods podcast server configuration.";
  };
}
