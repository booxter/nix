{ lib, ... }:
{
  options.host.network = {
    lanDomain = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "home.arpa";
      description = "Local network DNS domain.";
    };

    primaryInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Primary network interface for host services.";
    };
  };
}
