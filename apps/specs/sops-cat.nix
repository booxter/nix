{ facts, pkgs, ... }:
{
  package = (import ../sops { inherit facts pkgs; }).packages.sops-tools;
  description = "Decrypt and print a host secret.";
}
