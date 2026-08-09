{ facts, pkgs, ... }:
{
  package = (import ../fleet.nix { inherit facts pkgs; }).packages.wg-home-client-config;
  description = "Generate a home WireGuard client config from fleet topology.";
}
