{ lib, ... }:
{
  options.host.network.primaryInterface = lib.mkOption {
    type = lib.types.nullOr lib.types.nonEmptyStr;
    default = null;
    description = "Primary network interface for host services.";
  };
}
