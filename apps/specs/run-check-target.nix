{
  fleetInventory,
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit fleetInventory outputs pkgs; }).packages.run-check-target;
  description = "Build repository checks by name or as a complete set.";
}
