{ inputs, ... }:
{
  imports = [
    ./assertions.nix
    ./bridge-access.nix
    ./clients.nix
    ./namespaces.nix
    ./options.nix
    inputs.vpnconfinement.nixosModules.default
  ];
}
