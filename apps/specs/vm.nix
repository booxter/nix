{
  fleetInventory,
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit fleetInventory outputs pkgs; }).packages.vm;
  description = "Run a local NixOS host VM or a plain macOS development VM.";
}
