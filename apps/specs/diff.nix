{
  fleetInventory,
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit fleetInventory outputs pkgs; }).packages.diff;
  description = "Build and diff a NixOS or nix-darwin host configuration between two Git revisions.";
}
