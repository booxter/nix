{ outputs, pkgs, ... }:
{
  package = (import ../sops { inherit outputs pkgs; }).packages.sops-tools;
  description = "Edit a host secret.";
}
