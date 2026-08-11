{
  facts,
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit facts outputs pkgs; }).packages.vm;
  description = "Run a local NixOS VM for a nixosConfigurations host.";
}
