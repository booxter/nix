{
  config,
  fleetInventory,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      fleetInventory
      lib
      outputs
      ;
  };
in
{
  imports = [
    ./options.nix
    ./assertions.nix
    ./config.nix
  ];

  _module.args.autoUpgradeModel = model;
}
