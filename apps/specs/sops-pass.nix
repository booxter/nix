{ facts, pkgs, ... }:
{
  package = (import ../sops { inherit facts pkgs; }).packages.sops-tools;
  description = "Hash and store a NixOS login password.";
}
