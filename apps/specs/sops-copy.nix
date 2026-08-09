{ facts, pkgs, ... }:
{
  package = (import ../sops { inherit facts pkgs; }).packages.sops-tools;
  description = "Copy a top-level key path between host secrets.";
}
