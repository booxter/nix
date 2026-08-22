{
  fleetInventory,
  outputs,
  pkgs,
  ...
}:
{
  package =
    (import ../fleet.nix { inherit fleetInventory outputs pkgs; }).packages.wg-home-client-config;
  description = "Generate a home WireGuard client config from fleet topology.";
}
