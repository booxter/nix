{ outputs, pkgs, ... }:
{
  package = (import ../sops { inherit outputs pkgs; }).packages.sops-tools;
  description = "Merge missing template keys into a host secret.";
}
