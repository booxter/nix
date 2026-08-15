{
  config,
  lib,
  pkgs,
  storageModel,
  ...
}:
{
  imports = [
    ./assertions.nix
    ./auth.nix
    ./bootstrap.nix
    ./cache.nix
    ./container.nix
    ./database.nix
    ./storage.nix
    ./web.nix
  ];

  options.host.pinepods = lib.mkOption {
    type = lib.types.nullOr (lib.types.submodule { });
    default = null;
    description = "PinePods podcast server configuration.";
  };

  config._module.args.pinepodsModel = import ./model.nix {
    inherit config pkgs storageModel;
  };
}
