{
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit outputs pkgs; }).packages.deploy;
  description = "Apply fleet operations: host deploys (default) or disk provisioning (--disko).";
}
