{
  fleetInventory,
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit fleetInventory outputs pkgs; }).packages.vm;
  description = "Run a local VM for a NixOS or nix-darwin host.";
}
