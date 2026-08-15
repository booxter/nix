{ outputs, pkgs, ... }:
{
  package = (import ../sops { inherit outputs pkgs; }).packages.sops-tools;
  description = "Decrypt and print a host secret.";
}
