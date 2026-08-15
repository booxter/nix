{ outputs, pkgs, ... }:
{
  package = (import ../sops { inherit outputs pkgs; }).packages.sops-tools;
  description = "Copy a top-level key path between host secrets.";
}
