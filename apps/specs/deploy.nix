{
  facts,
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit facts outputs pkgs; }).packages.deploy;
  description = "Apply fleet operations: host deploys (default) or disk provisioning (--disko).";
}
