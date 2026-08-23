{
  fleetInventory,
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit fleetInventory outputs pkgs; }).packages.reset-oidc;
  description = "Send a Kanidm OIDC credential reset email through the realm provider.";
}
