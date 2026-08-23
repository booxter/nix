{ fleetInventory, pkgs, ... }:
{
  package = (import ../sops { inherit fleetInventory pkgs; }).packages.sops-tools;
  description = "Bootstrap host sops secrets and key recipients.";
}
