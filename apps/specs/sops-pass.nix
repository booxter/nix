{ fleetInventory, pkgs, ... }:
{
  package = (import ../sops { inherit fleetInventory pkgs; }).packages.sops-tools;
  description = "Hash and store a NixOS login password.";
}
