{
  facts,
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit facts outputs pkgs; }).packages.wg-home-client-config;
  description = "Generate a home WireGuard client config from fleet topology.";
}
