{ outputs, pkgs, ... }:
{
  package = (import ../sops { inherit outputs pkgs; }).packages.sops-tools;
  description = "Set a single host secret key path from stdin.";
}
