{
  fleetInventory,
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit fleetInventory outputs pkgs; }).packages.pki-rotation;
  description = "Inspect repo-managed internal PKI certificates and export rotation status.";
}
