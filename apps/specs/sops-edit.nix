{ facts, pkgs, ... }:
{
  package = (import ../sops { inherit facts pkgs; }).packages.sops-tools;
  description = "Edit a host secret.";
}
