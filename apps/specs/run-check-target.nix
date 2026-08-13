{
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit outputs pkgs; }).packages.run-check-target;
  description = "Build repository checks by name or as a complete set.";
}
