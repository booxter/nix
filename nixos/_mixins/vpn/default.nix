{
  config,
  inputs,
  lib,
  ...
}:
{
  imports = [
    ./assertions.nix
    ./bridge-access.nix
    ./clients.nix
    ./namespaces.nix
    ./options.nix
    inputs.vpnconfinement.nixosModules.default
  ];

  config._module.args.vpnModel = import ./model.nix { inherit config lib; };
}
