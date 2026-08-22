{
  fleetInventory,
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit fleetInventory outputs pkgs; }).packages.vm;
  description = "Run a local NixOS VM for a nixosConfigurations host.";
}
