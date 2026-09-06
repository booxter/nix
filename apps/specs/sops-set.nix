{ fleetInventory, pkgs, ... }:
{
  package = (import ../sops { inherit fleetInventory pkgs; }).packages.sops-tools;
  description = "Set a secret key path from stdin for one host or every host in a realm.";
}
