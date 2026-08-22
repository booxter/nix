{
  fleetInventory,
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit fleetInventory outputs pkgs; }).packages.deploy;
  description = "Apply fleet operations: host deploys (default) or disk provisioning (--disko).";
}
