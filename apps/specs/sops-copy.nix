{ fleetInventory, pkgs, ... }:
{
  package = (import ../sops { inherit fleetInventory pkgs; }).packages.sops-tools;
  description = "Copy a top-level key path between host secrets.";
}
