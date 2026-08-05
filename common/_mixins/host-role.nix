{
  hostInventory,
  hostname,
  lib,
  ...
}:
let
  hostSpec = hostInventory.hostSpecsByName.${hostname};
in
{
  options.host = {
    isBuilder = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      internal = true;
      description = "Whether this host is a Nix builder.";
    };

    isDesktop = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      internal = true;
      description = "Whether this host has a desktop environment.";
    };

    isLaptop = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      internal = true;
      description = "Whether this host is intermittently available like a laptop.";
    };

    isWork = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      internal = true;
      description = "Whether this is a work-managed host.";
    };
  };

  config.host = {
    isBuilder = hostSpec.isBuilder or false;
    isDesktop = hostSpec.isDesktop or false;
    isLaptop = hostSpec.isLaptop or false;
    isWork = hostSpec.isWork or false;
  };
}
