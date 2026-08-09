{ facts, pkgs, ... }:
{
  package = (import ../fleet.nix { inherit facts pkgs; }).packages.pki-rotation;
  description = "Inspect repo-managed internal PKI certificates and export rotation status.";
}
