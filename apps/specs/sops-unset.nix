{ fleetInventory, pkgs, ... }:
{
  package = (import ../sops { inherit fleetInventory pkgs; }).packages.sops-tools;
  description = "Delete a secret key path for one host or every host in a realm.";
}
